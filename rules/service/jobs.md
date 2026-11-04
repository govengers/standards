# Background jobs (`JOB`)

Profile: service

Durable background work goes through [govengers/jobs](https://github.com/govengers/jobs): a PostgreSQL queue that enqueues in the caller's transaction, claims with a lease, fences every write after the claim, retries with backoff, rescues the jobs of crashed workers and runs schedules once per period across replicas. The queue mechanics are the library's; these rules are about using it right.

### JOB-001 Durable work goes through govengers/jobs

- **Severity:** should
- **Principle:** P2, P5
- **Check:** durable work (mail, generation, sync, outbound webhooks) queued in memory or in fire-and-forget goroutines, where a restart loses it; a hand-rolled job table with its own claim, lease or retry code in a service; a separate broker (NATS, Redis Streams) while throughput needs are below thousands of jobs per second.

The jobs live in the service's own database, so they commit with the change that causes them (JOB-007), survive a restart and need no extra infrastructure. A queue written per project repeats the bugs the library's review found: stale finish writes after a lost lease, a heartbeat that never self-fences, recurring work that runs once per replica, a shutdown that aborts handlers mid-job. Existing hand-rolled queues move over with the library's [migration guide](https://github.com/govengers/jobs/blob/main/docs/wiki/Migration.md). Reach for a broker only for sub-second dispatch or very high throughput.

```go
// the contract, shared by the code that enqueues and the handler
type WelcomeMailPayload struct {
    UserID uuid.UUID `json:"userId"`
}

var WelcomeMailKind = jobs.NewKind[WelcomeMailPayload]("user.welcome-mail", &jobs.KindOptions{
    Queue:           "mail",
    MaximumAttempts: 8,
})
```

### JOB-002 Claim jobs with `FOR UPDATE SKIP LOCKED` and a lease

- **Status:** deprecated (31.10.2026, govengers/jobs claims with `FOR UPDATE SKIP LOCKED`, fences every write with a lease token and rescues expired leases; JOB-001)

### JOB-003 Handlers are idempotent

- **Severity:** must
- **Principle:** P6
- **Check:** a job handler that causes duplicate external effects when it runs twice for the same job.

Delivery is at least once. A handler runs again after a crash between its effect and the finish write, after a lost lease (a partition, a database outage longer than the lease) and after a rescue. Use the job ID as the idempotency key for external calls (RES-004), and check-then-act inside a transaction for internal effects.

```go
// bad: a second run sends a second mail
return c.options.Mailer.Send(ctx, message)

// good: the provider deduplicates on the job's ID
return c.options.Mailer.Send(ctx, message, mailer.IdempotencyKey(job.ID.String()))
```

### JOB-004 Configure every consumed queue and size the pool for the worker

- **Severity:** should
- **Principle:** P3, P6
- **Check:** queue concurrency, lease or poll intervals hard-coded in a component instead of passed from `main` (CFG-006); the queues a Deployment consumes fixed in code instead of read from configuration (`JOB_QUEUES`); a `pgxpool` `MaxConns` no larger than the handlers' total concurrency.

| Setting | Guidance |
|---------|----------|
| `QueueOptions.Concurrency` | jobs of the queue running at once in one process |
| `QueueOptions.LeaseDuration` | the default fits: the heartbeat extends the lease every LeaseDuration/3, so it does not depend on how long a job takes |
| `QueueOptions.PollInterval` | how fast an idle queue notices a new job |
| `JOB_QUEUES` | which queues this Deployment consumes; one image, several Deployments (P10) |

The heartbeat, finish writes, claims, the rescuer and schedule checks use the same pool as the handlers. A pool sized to the handlers alone makes the heartbeat wait, and a heartbeat that cannot confirm a lease for longer than the lease cancels a healthy handler. Size `MaxConns` for both, or give the store its own pool.

### JOB-005 Workers stop gracefully

- **Severity:** must
- **Principle:** P6
- **Check:** `worker.Run` not started in the errgroup `main` waits on, or not wrapped in `recovering` (CON-001); a `DrainTimeout` that does not fit inside the pod's grace period next to the HTTP drain (LAY-003); a handler that ignores its context, so it keeps its job past the drain.

On cancellation the worker stops claiming, lets running handlers finish until `DrainTimeout`, then cancels their contexts and hands their jobs back to another replica without counting the attempt.

```go
worker, err := jobs.NewWorker(&jobs.WorkerOptions{
    Store:        jobStore,
    Queues:       jobQueues, // from JOB_QUEUES
    Middleware:   []jobs.Middleware{jobEvents},
    Propagators:  []jobs.Propagator{authadapter.Identity()},
    Observer:     jobMetrics,
    DrainTimeout: 20 * time.Second, // inside the 30 s grace period
})
if err != nil {
    return fmt.Errorf("create job worker: %w", err)
}
if err := jobs.Handle(worker, user.WelcomeMailKind, welcomeMailJobController.Send); err != nil {
    return fmt.Errorf("register welcome mail handler: %w", err)
}
group.Go(recovering(func() error { return worker.Run(ctx) })) // main waits on group.Wait() (CON-001)
```

### JOB-006 Evolve payloads additively; a breaking change is a new kind

- **Severity:** should
- **Principle:** P4, P6
- **Check:** a field of a kind's payload renamed, removed or retyped while jobs of the old shape can still be pending (rolling deploys, retries, scheduled runs); a payload that carries data instead of references (a whole entity, a file); a handler that decodes the payload itself and ignores the error.

The library decodes payloads tolerantly, unknown fields are ignored, so a newer producer and an older worker coexist during a rollout, and a payload that does not decode is dead at once with the decode error. A breaking change gets a new kind name (`user.welcome-mail.v2`); keep the old handler until no job of the old kind is pending. A payload holds IDs; the handler loads the current state.

### JOB-007 Enqueue in the transaction of the change that causes the job

- **Severity:** must
- **Principle:** P5, P6
- **Check:** `Enqueue` with the pool after the repository committed the domain change, for work that must not be lost or must not happen for a rolled-back change; an enqueue in the service layer, outside the repository that owns the transaction (DAT-001).

An enqueue after the commit loses the job when the process dies in between; an enqueue before the commit sends the mail of a sign-up that then rolls back. The repository writes the domain row and the job in one transaction, its own or livewire's (`livewire.TransactionFrom(ctx)`).

```go
// bad: two transactions, the mail is lost when the enqueue fails after the commit
created, err := s.options.UserRepository.Create(ctx, input)
if err != nil {
    return nil, err
}
_, err = s.options.JobStore.Enqueue(ctx, s.options.Pool, user.WelcomeMailKind.New(user.WelcomeMailPayload{UserID: created.ID}, nil))

// good: in the repository, the job commits or rolls back with the user
row, err := r.queries.WithTx(transaction).CreateUser(ctx, toCreateUserParams(input))
if err != nil {
    return nil, mapError(err)
}
_, err = r.options.JobStore.Enqueue(ctx, transaction, user.WelcomeMailKind.New(user.WelcomeMailPayload{UserID: row.ID}, nil))
if err != nil {
    return nil, fmt.Errorf("enqueue welcome mail for user %s: %w", row.ID, err)
}
```

### JOB-008 A handler is a job controller

- **Severity:** should
- **Principle:** P1, P3
- **Check:** business logic in a handler (it queries, decides or mutates itself) instead of calling a service method; a service method that takes a `*jobs.Job`; a domain error no retry fixes (not found, invalid) returned as a plain error, so the job retries until it is dead.

The job is a transport like HTTP: the handler translates it and calls the same service method a controller calls (ARC-001), so REST, a job and a test exercise one code path. Errors that a retry cannot fix become `jobs.Permanent`.

```go
func (c *WelcomeMailJobController) Send(ctx context.Context, job *jobs.Job[user.WelcomeMailPayload]) error {
    err := c.options.UserService.SendWelcomeMail(ctx, job.Payload.UserID)
    if errors.Is(err, model.ErrNotFound) {
        return jobs.Permanent(err) // the user is gone; no retry brings them back
    }
    return err
}
```

### JOB-009 Recurring work runs as a `jobs.Schedule`

- **Severity:** must
- **Principle:** P6
- **Check:** a `time.Ticker` or a cron library in every replica for work that must run once per period; a schedule whose `Next` depends on the replica (its local clock, its host name).

A ticker per replica runs the nightly invoice job once per pod. A `jobs.Schedule` is claimed with `SKIP LOCKED` by one worker per period, which enqueues the job and advances the schedule in one transaction; periods missed while nothing ran are enqueued once. A scheduled job carries no values of `Run`'s context: it acts as the system (INT-002).

```go
// bad: three replicas, three invoice runs
ticker := time.NewTicker(24 * time.Hour)

// good
Schedules: []jobs.Schedule{{
    Name: "billing.nightly-invoices",
    Next: jobs.DailyAt(2, 30, berlin),
    Job:  billing.NightlyInvoicesKind.New(billing.NightlyInvoicesPayload{}, nil),
}},
```

### JOB-010 Every attempt has a wide event and metrics

- **Severity:** should
- **Principle:** P7
- **Check:** a worker without the `wideeventadapter` middleware (LOG-001) or without the `prometheusadapter` Observer (MET-006); no alert on dead jobs or on the oldest pending job's age; queue depth gauges summed across replicas.

One wide event per attempt records the job, the attempt, the stored result and everything the layers below add. The depth gauges read the shared table at scrape time, so every replica reports the same value: aggregate them with `max`, not `sum`.

```go
jobEvents, err := wideeventadapter.NewMiddleware(&wideeventadapter.Options{Emitter: emitter})
if err != nil {
    return fmt.Errorf("create job wide events: %w", err)
}
jobMetrics, err := prometheusadapter.New(&prometheusadapter.Options{
    Registerer:  registry,
    Namespace:   "billing",
    DepthSource: jobStore,
    Queues:      []string{"mail", "invoices"},
})
if err != nil {
    return fmt.Errorf("register job metrics: %w", err)
}
```

A service that traces (TRC-001) adds `oteladapter`: the propagator on the store and the worker carries the enqueuing request's trace into the job, and the middleware, placed after `wideeventadapter`, opens one span per attempt and writes `trace.id` onto the attempt's event (TRC-003, TRC-005).

```go
jobSpans, err := oteladapter.NewMiddleware(&oteladapter.Options{TracerProvider: traces.TracerProvider()})
if err != nil {
    return fmt.Errorf("create job spans: %w", err)
}
// postgresadapter.Options.Propagators and jobs.WorkerOptions.Propagators: oteladapter.NewPropagator()
// jobs.WorkerOptions.Middleware: []jobs.Middleware{jobEvents, jobSpans}
```

### JOB-011 A job a user started acts as that user

- **Severity:** should
- **Principle:** P7
- **Check:** a service whose jobs act for users without `authadapter.Identity()` in the store's and the worker's propagators, so audit rows of user-started jobs name the system user (INT-002); a handler that treats the propagated identity as fresh, although it is the snapshot taken at enqueue.

The identity travels with the job and is restored before the handler runs, so the audit says who started the work. It is a snapshot: a right revoked after the enqueue does not reach the job. A handler whose action needs the current rights checks them again.

```go
jobStore, err := postgresadapter.New(&postgresadapter.Options{
    Pool:        pool,
    Propagators: []jobs.Propagator{authadapter.Identity()},
})
```
