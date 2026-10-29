# Resilience for outbound calls (`RES`)

Profile: core

### RES-001 Every outbound call has a timeout

- **Severity:** must
- **Principle:** P6
- **Check:** `http.DefaultClient`, `http.Get`, `http.Post` or an `&http.Client{}` without `Timeout`; outbound requests built without a context (`http.NewRequest` instead of `http.NewRequestWithContext`; `noctx` lint).

The default client waits forever. A hung dependency then hangs every goroutine that calls it.

```go
// bad
response, err := http.Get(url)

// good
httpClient := &http.Client{Timeout: 10 * time.Second}
request, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
```

### RES-002 Retry only transient failures

- **Severity:** must
- **Principle:** P6
- **Check:** retry loops that retry every error, including `context.Canceled`, `context.DeadlineExceeded`, 4xx other than 429, or decode errors.

| Retry | Do not retry |
|-------|--------------|
| HTTP 429, 5xx | `context.Canceled`, `context.DeadlineExceeded` |
| transport errors (`io.EOF`, connection reset) | HTTP 4xx except 429 |
| | marshal / unmarshal errors |

### RES-003 Back off exponentially with jitter, and stop on cancel

- **Severity:** must
- **Principle:** P6
- **Check:** fixed-delay retries; `time.Sleep` in a retry loop (ignores cancellation); no cap on the delay; jitter computed in a way that can panic on small durations (`rand.Intn(int(d/5))` with `d/5 == 0`).

```go
for attempt := range maximumAttempts {
    if attempt > 0 {
        backoff := min(base<<(attempt-1), 16*base)
        backoff += rand.N(backoff/5 + 1) // math/rand/v2, 0-20% jitter
        select {
        case <-time.After(backoff):
        case <-ctx.Done():
            return nil, ctx.Err()
        }
    }
    response, err := c.do(ctx, request)
    if err == nil || !isTransient(err) {
        return response, err
    }
    lastError = err
}
return nil, fmt.Errorf("giving up after %d attempts: %w", maximumAttempts, lastError)
```

Respect a `Retry-After` header when the server sends one. Record each retry (attempt count, last error) on the wide event (LOG-004).

### RES-004 Retry only idempotent operations

- **Severity:** must
- **Principle:** P6
- **Check:** automatic retry of a non-idempotent call (payment, email send, POST that creates) without an idempotency key.

A blind retry after a timeout can charge twice. Send an idempotency key the server deduplicates on, or do not retry.

### RES-005 Retry streams only before the first byte

- **Severity:** must
- **Principle:** P6
- **Check:** a streaming call (SSE, chunked LLM responses) retried after data has been consumed.

Retrying mid-stream duplicates output and, for metered APIs, bills twice for the tokens already received.

### RES-006 Fit retries inside the caller's deadline

- **Severity:** should
- **Principle:** P6
- **Check:** retry budget (attempts x per-attempt timeout + backoff) larger than the deadline of the context it runs under, with no per-attempt timeout.

Otherwise the last attempt always times out and the retry logic only adds latency.

### RES-007 Optional dependencies degrade, required ones fail fast

- **Severity:** should
- **Principle:** P6
- **Check:** a service that refuses to serve when an optional integration (email, payment sync, AI provider) is down; or one that starts serving although a required dependency (database) is unreachable.

Check required dependencies at startup and exit on failure. For optional ones, return a cached value or a clear "temporarily unavailable" and keep the rest of the service up.
