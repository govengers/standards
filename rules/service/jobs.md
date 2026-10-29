# Background jobs (`JOB`)

Profile: service

### JOB-001 Durable jobs live in Postgres

- **Severity:** should
- **Principle:** P2, P5
- **Check:** durable work (emails, generation, sync) queued in memory or fire-and-forget goroutines, where a restart loses it; a separate broker added while throughput needs are below thousands of jobs per second.

A job table enqueued in the same transaction as the domain change has no two-phase consistency problem, recovers trivially after a crash, and needs no extra infrastructure. Reach for NATS or Redis Streams only for sub-second dispatch or very high throughput.

### JOB-002 Claim jobs with `FOR UPDATE SKIP LOCKED` and a lease

- **Severity:** must
- **Principle:** P5, P6
- **Check:** job claiming by `SELECT` then `UPDATE` without a lock; claims without `locked_until`; no reaper for expired leases.

```sql
-- name: ClaimJobs :many
UPDATE work_queue_jobs SET
    status = 'processing',
    locked_by = @worker_id,
    locked_until = now() + @lease::interval,
    attempt_count = attempt_count + 1
WHERE id IN (
    SELECT id FROM work_queue_jobs
    WHERE queue = @queue AND status = 'pending' AND scheduled_for <= now()
    ORDER BY scheduled_for
    LIMIT @batch
    FOR UPDATE SKIP LOCKED
)
RETURNING *;
```

One statement claims atomically: replicas skip each other's rows instead of waiting. A reaper moves jobs whose `locked_until` passed back to `pending`, or to `dead` once `attempt_count >= max_attempts`.

### JOB-003 Handlers are idempotent

- **Severity:** must
- **Principle:** P6
- **Check:** a job handler that causes duplicate external effects when it runs twice for the same job (lease expiry, crash after the effect but before completion).

At-least-once delivery is the only guarantee. Use idempotency keys for external calls (RES-004) and check-then-act inside a transaction for internal effects.

### JOB-004 Tune lease, poll and reap intervals to the job

- **Severity:** should
- **Principle:** P6
- **Check:** a lease shorter than the job's p99 duration (duplicates) or far longer (slow recovery); hard-coded intervals that cannot be changed through options.

| Parameter | Guidance |
|-----------|----------|
| lease | longer than job p99 |
| poll interval | 5-10 s for background work |
| reap interval | 30-60 s |

### JOB-005 Workers stop gracefully

- **Severity:** must
- **Principle:** P6
- **Check:** a worker pool that is not stopped and awaited on shutdown (LAY-003), or that abandons a running job without releasing its lease.

```go
generationQueue, err := workqueue.New(&workqueue.Options{
    Parallelism:   3,
    PollInterval:  5 * time.Second,
    ReapInterval:  30 * time.Second,
    JobRepository: jobRepository,
    Handler:       generationService.HandleJob, // nil = completed, error = retry
})
if err != nil {
    return err
}
group.Go(recovering(func() error { return generationQueue.Run(ctx) })) // returns when ctx is cancelled and running jobs finished; main waits on group.Wait() (CON-001)
```

### JOB-006 Handlers decode payloads strictly and fail permanently on bad data

- **Severity:** should
- **Principle:** P4
- **Check:** `json.Unmarshal` errors on a job payload ignored; malformed payloads retried until `max_attempts`.

A payload that cannot be decoded will never succeed. Mark the job dead immediately with the decode error.
