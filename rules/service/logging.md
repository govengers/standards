# Logging (`LOG`)

Profile: service. Library: `github.com/govengers/wide-event-logger` v1 (package `wideevent`, Gin middleware in `ginadapter`).

We log in wide events. Each unit of work (request, job, cron run, consumer message) produces **one** structured event, and everything that happens during that work is recorded on it: every failure, every business decision, every technical interaction on every layer. When something goes wrong in production, the event for that request should answer what happened without anyone reproducing it.

```json
{
  "name": "update_product",
  "outcome": "failure",
  "error": "update product 0192...: conflict",
  "request": { "method": "PUT", "path": "/api/v1/products/0192..." },
  "response": { "status": 409 },
  "user": { "id": "0191...", "role": "admin" },
  "product": { "id": "0192...", "changed_fields": ["name"] },
  "db": { "queries": 3, "duration_ms": 4.1, "tx": "rolled_back" },
  "cache": { "hit": true },
  "duration": 6.8
}
```

### LOG-001 Every unit of work has exactly one wide event

- **Severity:** must
- **Principle:** P7
- **Check:** HTTP routes not covered by the `ginadapter.NewMiddleware` middleware; jobs, cron runs, queue consumers, WebSocket message handlers or startup tasks without their own `wideevent.Begin(...)` and a deferred `Emit()`; units of work that emit several events.

The middleware creates the request event and emits it after the handler. Everything else starts its own and puts it into the context, so the layers below can find it.

```go
func (w *Worker) handle(ctx context.Context, job *model.Job) (err error) {
    we := wideevent.Begin(w.options.Emitter, "job."+job.Queue)
    defer func() {
        if recovered := recover(); recovered != nil {
            err = fmt.Errorf("job %s panicked: %v", job.ID, recovered) // record it as a failure, not as a success
        }
        if err != nil {
            we.Failure(err)
        } else {
            we.Success()
        }
        we.Emit()
    }()
    we.UUID("job.id", job.ID).Int("job.attempt", job.Attempt)
    ctx = wideevent.NewContext(ctx, we)
    return w.options.Handler(ctx, job)
}
```

### LOG-002 Every failure ends up in the wide event

- **Severity:** must
- **Principle:** P4, P7
- **Check:** an error that is handled without being recorded: swallowed, replaced by a fallback, retried, downgraded to a default, or ignored with `_ =`, and no `we.Err(...)` at that point; a returned error that reaches the decision point (handler, job runner) without `we.Failure(err)`.

There are two kinds of failure, and both are recorded exactly once ([ERR-003](../core/errors.md#err-003-handle-and-log-an-error-exactly-once)):

| Failure | Recorded | How |
|---------|----------|-----|
| returned up the stack | at the decision point | `we.Failure(err)` (sets `outcome` and `error`) |
| handled locally (fallback, retry, ignore) | where it is handled | `we.Err("<area>.error", err)` plus a field saying what was done instead, and `degraded=true` |

```go
// bad: the cache backend is down and nobody will ever know
user, err := r.userCache.Get(ctx, id)
if err != nil {
    user, err = r.loadUser(ctx, id)
}

// good
user, err := r.userCache.Get(ctx, id)
if err != nil {
    wideevent.FromContext(ctx).Err("cache.error", err).String("cache.fallback", "database").Bool("degraded", true)
    user, err = r.loadUser(ctx, id)
}
```

The same applies to retries (`http.attempts`, `http.last_error`), validation failures (`validation.error`), authorization denials (`authz.denied`, `authz.reason`), and errors deliberately ignored (`close.error`).

### LOG-003 Record every business-relevant interaction

- **Severity:** must
- **Principle:** P7
- **Check:** a handler, service or job that performs a business action (create, update, delete, state transition, permission decision, payment, notification) without recording on the event what was done, to which object, by whom, and with which result.

At minimum: the action, the IDs of the affected objects, the actor, the outcome, and the decision values that drove a branch.

```go
we.String("action", "subscription.cancel").
    UUID("business.id", businessID).
    String("subscription.status_before", string(before.Status)).
    String("subscription.status_after", string(after.Status)).
    Bool("subscription.refund_issued", refunded)
```

Record the actor once per request in a middleware or pre-enricher (`we.UserID(user.ID).UserRole(string(user.Role))`), not in every handler.

### LOG-004 Record every technical interaction, on every layer

- **Severity:** must
- **Principle:** P7
- **Check:** an I/O boundary (database, cache, outbound HTTP, queue, object storage, email, WebSocket broadcast, external SDK) that does not add its operation, target, result and duration to the context's wide event.

Each layer adds fields under its own namespace. Nothing is too small to record if it can fail or be slow.

| Namespace | Fields |
|-----------|--------|
| `db` | `operation`, `entity`, `rows`, `queries`, `duration_ms`, `tx` (`committed`, `rolled_back`) |
| `cache` | `hit`, `backend`, `error`, `fallback` |
| `http.<service>` | `method`, `status`, `attempts`, `duration_ms`, `error` |
| `queue` | `job.id`, `job.queue`, `job.attempt`, `enqueued` |
| `storage` | `bucket`, `key`, `bytes`, `duration_ms` |
| `ws` | `recipients`, `dropped` |
| `email` | `template`, `provider_id` |

```go
start := time.Now()
response, err := c.httpClient.Do(request)
we := wideevent.FromContext(ctx)
we.Duration("http.stripe.duration", time.Since(start)).Int("http.stripe.attempts", attempt+1)
if response != nil {
    we.Int("http.stripe.status", response.StatusCode)
}
we.Err("http.stripe.error", err)
```

Put the instrumentation into the shared client, repository helper or middleware once, so individual call sites do not have to remember it.

### LOG-005 Use stable, namespaced keys

- **Severity:** should
- **Principle:** P1, P7
- **Check:** keys without a namespace (`count`, `id`, `status`); the same concept under different keys across the code (`userId`, `user_id`, `user.id`); keys built from data (`fmt.Sprintf("item_%d", i)`).

Keys are `<namespace>.<field>` in lowercase snake_case. Dots nest in the JSON output. A key is a column in the log store; dynamic keys make it unqueryable.

### LOG-006 Aggregate inside loops

- **Severity:** must
- **Principle:** P6, P7
- **Check:** `we.Set`/`Str`/`Err` called once per iteration of a loop over data.

Every setter appends a field, so per-iteration writes grow the event without limit. Record counts, totals, and the first error (or the first few IDs) instead.

```go
// bad
for _, item := range items {
    we.String("item.id", item.ID.String())
}

// good
we.Int("import.items", len(items)).Int("import.failed", failed).Err("import.first_error", firstError)
```

### LOG-007 Guard against a missing event

- **Status:** deprecated (30.10.2026, wide-event-logger v1: every method of a nil `*wideevent.Event` does nothing, so `wideevent.FromContext(ctx).String(...)` is safe without a nil check)

### LOG-008 Never write to an event after it was emitted

- **Severity:** must
- **Principle:** P7
- **Check:** a goroutine started from a handler that enriches the request's wide event (via `ginadapter.FromContext`/`wideevent.FromContext`) after the response may already have been sent.

The middleware emits once when the handler returns, and later writes are silently lost. Detached work (CON-003) starts its own event with `wideevent.Begin` and carries the request ID from the parent so the two can be correlated.

```go
requestID := ginContext.Writer.Header().Get(ginadapter.RequestIDHeader) // the middleware sets it, generated if the client sent none
detached := context.WithoutCancel(ctx)
safeGo(func() {
    we := wideevent.Begin(emitter, "notify_subscribers")
    defer we.Emit()
    we.String("request.parent_id", requestID)
    notifySubscribers(wideevent.NewContext(detached, we), item)
})
```

### LOG-009 No secrets or personal data in events

- **Severity:** must
- **Principle:** P6
- **Check:** passwords, tokens, API keys, session IDs, full request or response bodies, email addresses, names or free-text user input written to the event; a `QueryAllowlist` of the `ginadapter` middleware that names a parameter carrying secrets or personal data (tokens, codes, emails, search terms).

Record IDs, not personal data. Events go to a shared log store with longer retention and wider access than the database. The middleware records `request.query` with every value replaced by `redacted`; allow only the parameters known to be harmless:

```go
middleware, err := ginadapter.NewMiddleware(&ginadapter.Options{
    Emitter:        emitter,
    QueryAllowlist: []string{"limit", "offset", "sort", "order"},
})
```

### LOG-010 Keep every error and every degraded event when sampling

- **Severity:** must
- **Principle:** P7
- **Check:** a sampler that can drop events with `outcome=failure`, status 5xx, or `degraded=true`; head sampling decided before the work ran.

`HasError()` only sees `Failure()` and 5xx, so handled failures (LOG-002) need their own sampling rule.

```go
keepDegraded := wideevent.SamplerFunc(func(candidate *wideevent.Event) bool {
    degraded, _ := candidate.FieldsMap()["degraded"].(bool)
    return degraded
})

middleware, err := ginadapter.NewMiddleware(&ginadapter.Options{
    Emitter: wideevent.SampledEmitter(emitter, wideevent.CompositeSampler(
        wideevent.AlwaysOnError(),
        wideevent.AlwaysOnStatus(http.StatusUnauthorized, http.StatusForbidden, http.StatusConflict),
        keepDegraded,
        wideevent.Rate(10), // every 10th of the rest
    )),
    SkipPaths: []string{"/api/health"},
})
```

Business events that must never be lost (payments, permission changes) belong in the audit log ([INT-001](data-integrity.md#int-001-audit-every-mutation-in-the-same-transaction)), not only in sampled logs.

### LOG-011 Every event states its outcome

- **Severity:** should
- **Principle:** P7
- **Check:** a handler or job that returns without `we.Success()` or `we.Failure(err)`.

The level is inferred from the outcome and status. An explicit outcome makes "failed but returned 200" (partial imports, best-effort operations) visible.

### LOG-012 Standalone log lines only outside a unit of work

- **Severity:** must
- **Principle:** P7
- **Check:** `log.Info()`/`Warn()`/`Error()` (zerolog) or `fmt.Print*` inside request handling, services, repositories or jobs; per-request access logs at info level.

Plain log lines are for what happens outside any unit of work: startup, config print, migrations, shutdown, fatal errors before the emitter exists. Everything else goes into the wide event. Levels for those lines: info for lifecycle, warn for degraded startup, error for failures.

### LOG-013 Use the dev emitter locally and JSON in production

- **Severity:** should
- **Principle:** P7, P10
- **Check:** JSON output in local dev, or the colorized dev emitter in a deployed environment.

```go
var emitter wideevent.Emitter = wideevent.NewJSONEmitter(nil) // stdout
if configuration.DevMode {
    devEmitter, err := wideevent.NewDevEmitter(nil)
    if err != nil {
        return err
    }
    emitter = devEmitter
}
```

### LOG-014 Test that failures are recorded

- **Severity:** should
- **Principle:** P7, P9
- **Check:** critical failure paths (payment, auth, external sync fallback) without a test that asserts the wide event records the failure.

Capture events with an `EmitterFunc` and assert on `FieldsMap()`.

```go
var got *wideevent.Event
emitter := wideevent.EmitterFunc(func(emitted *wideevent.Event) { got = emitted })
// ... run the request with a cache backend that fails ...
require.Equal(t, true, got.FieldsMap()["degraded"])
require.Equal(t, "database", got.FieldsMap()["cache"].(map[string]any)["fallback"])
```
