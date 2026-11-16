# Events and webhooks (`EVT`)

Profile: service. Library: [`github.com/govengers/events`](https://github.com/govengers/events) on top of govengers/jobs: typed, versioned topics in a CloudEvents envelope, published in the caller's transaction, delivered to local subscriptions as jobs and to remote ones as signed (Standard Webhooks) POSTs to the subscriber's inbox, plus `safehttp`, a client for URLs someone else chose. Events stay a contract between services; work inside one service is a job (JOB-001).

### EVT-001 Publish in the transaction of the change

- **Severity:** must
- **Principle:** P5, P6
- **Check:** `Publish` with the pool after the change committed, or in a transaction of its own; an event sent over HTTP from a request handler; a hand-rolled outbox table or webhook sender.

Published with the change's transaction, the event and the change commit together: a rolled-back order announces nothing, and a committed one is delivered even when the process dies right after the commit. The repository that owns the transaction publishes (JOB-007, DAT-001), with livewire's transaction when the engine runs the mutation (`postgresadapter.TransactionFrom(ctx)`).

```go
// in the repository, inside the transaction that marks the order paid
_, err = r.options.EventStore.Publish(ctx, transaction, contract.OrderPaidTopic.New(contract.OrderPaid{OrderID: row.ID, Version: row.Version}))
if err != nil {
    return fmt.Errorf("publish order %s paid: %w", row.ID, err)
}
```

### EVT-002 Handlers are idempotent and order-blind

- **Severity:** must
- **Principle:** P6
- **Check:** a subscription handler that repeats an external effect when the same event arrives twice; a handler that assumes events arrive in publish order; business logic in the handler instead of a service method (JOB-008).

Delivery is at least once and unordered: a retry, a redelivery by an administrator and two replicas racing all happen. Key effects by the aggregate and the event's version and drop an update older than the state you have; deduplicate external calls with the event ID (RES-004). A handler is a jobs handler and follows the job rules.

### EVT-003 Events are small, versioned references

- **Severity:** should
- **Principle:** P4
- **Check:** an event that carries a whole document or a file; a topic whose payload shape changed incompatibly under the same version; an event without the aggregate's version when subscribers apply updates.

An event is at most 32 KiB and stored as jsonb. It carries IDs, the version and the few fields a subscriber filters on; the subscriber fetches the rest from the publisher's API. Payloads evolve additively; a breaking change is a new topic version, published next to the old one until no subscriber reads it (like JOB-006).

### EVT-004 Inboxes verify the signature, registrations authenticate the caller

- **Severity:** must
- **Principle:** P6
- **Check:** an inbox route behind session or API key authentication, or one that does not verify the signature (API-012); a registration route without authentication and `Options.Authorize`; http endpoints in production (`Options.AllowHTTP` on outside development).

The inbox's requests are authenticated by their signature, so it must not demand a session the publisher does not have. The registration route carries API keys and signing secrets: it needs the API key middleware, and `Authorize` checks that the caller is the subscriber it registers and may read the topics and endpoints it names.

### EVT-005 Call URLs someone else chose only through a safe client

- **Severity:** must
- **Principle:** P6
- **Check:** `http.DefaultClient`, `http.Get` or an own `http.Client` used for a URL that a user, a tenant or a subscriber supplied (webhook endpoints, link previews, avatar or feed fetches, import from URL); an address check before the request instead of in the dialer; redirects followed without a bound; a response read without a size limit.

A user-chosen URL can point at the cluster's internal services, the cloud metadata endpoint (`169.254.169.254`) or the loopback interface (server-side request forgery). A check before the request does not help: DNS can answer differently when the client dials. `safehttp.New` checks the resolved address at dial time on every connection and redirect, refuses private, loopback, link-local and metadata ranges, reads no proxy from the environment, and bounds redirects, response size and time. Inside a cluster, allow exactly the service network with `AllowedNetworks` rather than every private network.

```go
// bad
response, err := http.Post(subscription.EndpointURL, "application/json", body)

// good: built once in main and passed in through the options
client, err := safehttp.New(&safehttp.Options{Timeout: 10 * time.Second, MaximumResponseBytes: 1 << 20})
```

### EVT-006 Seal secrets at rest

- **Severity:** must
- **Principle:** P6
- **Check:** a webhook signing secret, TOTP secret, OAuth token or third-party API key stored in clear text in a column; a sealed value not bound to its row (the same ciphertext opens under another row); a seal key without rotation (one key, no key ID); a secret the service shows once kept in the idempotency record or a log.

A database dump, a backup or a read replica must not hand out credentials. govengers/auth's `seal` package seals with AES-256-GCM under a key ring (`SEAL_KEYS`, a `.Sensitive()` value: the first key seals, every key opens) and binds each value to its purpose, table and row through the associated data. govengers/events and govengers/mail take an own `Sealer` interface; a ten-line wrapper adapts the key ring. A new secret (an API key, a webhook secret) is shown once: its mutation is marked `SecretResponse` in livewire, so the idempotency record keeps no copy.
