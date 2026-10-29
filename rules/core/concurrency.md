# Concurrency and context (`CON`)

Profile: core

### CON-001 Recover panics in every goroutine you start

- **Severity:** must
- **Principle:** P4, P6
- **Check:** a bare `go func()` or `go x()` in application code, or `errgroup.Go` with a function that is not wrapped in `recovering`, outside a worker pool that recovers on its own.

A panic in a goroutine crashes the whole process; the HTTP server's recovery middleware only covers the request goroutine. For errgroup tasks, turn the panic into the task's error, so the owner sees it and the group cancels the rest. `safeGo` is for fire-and-forget work in services; a library returns the error to its owner instead of logging (LIB-003).

```go
// recovering turns a panic in work into an error for its errgroup.
func recovering(work func() error) func() error {
    return func() (err error) {
        defer func() {
            if recovered := recover(); recovered != nil {
                err = fmt.Errorf("panic: %v\n%s", recovered, debug.Stack())
            }
        }()
        return work()
    }
}
```

```go
func safeGo(work func()) {
    go func() {
        defer func() {
            if recovered := recover(); recovered != nil {
                log.Error().Interface("panic", recovered).Bytes("stack", debug.Stack()).Msg("recovered panic in goroutine")
            }
        }()
        work()
    }()
}

// bad
go h.deliver(message)

// good
safeGo(func() { h.deliver(message) })
```

### CON-002 `context.Context` is the first parameter, never stored

- **Severity:** must
- **Principle:** P3
- **Check:** a function doing I/O without a `ctx context.Context` first parameter; `context.Background()` or `context.TODO()` inside request-handling code; a context stored in a struct field.

```go
// bad
func (s *StorageAdapter) GetUserByUsername(username string) (*User, error) {
    return s.options.UserRepository.GetByUsername(context.Background(), username)
}

// good
func (s *StorageAdapter) GetUserByUsername(ctx context.Context, username string) (*User, error) {
    return s.options.UserRepository.GetByUsername(ctx, username)
}
```

When a third-party interface has no context parameter, document the gap at the adapter with a comment.

### CON-003 Detach work that outlives the request with `context.WithoutCancel`

- **Severity:** must
- **Principle:** P6
- **Check:** a goroutine started from a handler that uses the request context (`ginContext.Request.Context()`, the handler's `ctx`) for work that continues after the response is sent.

The request context is cancelled when the handler returns, aborting the work midway. `WithoutCancel` keeps the values (actor, trace) and drops the cancellation. Give the detached work its own timeout and its own wide event: the request event is already emitted ([LOG-008](../service/logging.md#log-008-never-write-to-an-event-after-it-was-emitted)).

```go
// bad
go s.notifySubscribers(ctx, item)

// good
detached := context.WithoutCancel(ctx)
safeGo(func() {
    ctx, cancel := context.WithTimeout(detached, 30*time.Second)
    defer cancel()
    we := wideevent.Begin(s.options.Emitter, "notify_subscribers")
    defer we.Emit()
    s.notifySubscribers(wideevent.NewContext(ctx, we), item)
})
```

### CON-004 Guard shared state

- **Severity:** must
- **Principle:** P4
- **Check:** a map, slice or struct field read and written from more than one goroutine without a mutex, `sync.Map`, atomic or channel ownership. `go test -race` must pass.

```go
// bad
type Broadcaster struct {
    sessions map[uuid.UUID]chan *ChatFrame
}

// good
type Broadcaster struct {
    mutex    sync.RWMutex
    sessions map[uuid.UUID]chan *ChatFrame
}

func (b *Broadcaster) SendToSession(sessionID uuid.UUID, frame *ChatFrame) {
    b.mutex.RLock()
    frames, ok := b.sessions[sessionID]
    b.mutex.RUnlock()
    ...
}
```

### CON-005 Never block forever on a channel send

- **Severity:** must
- **Principle:** P6
- **Check:** a send to a channel whose reader may be gone or slow (per-client channels, subscriber fan-out) without a `select` on `ctx.Done()`, a `default` case or a timeout.

One stuck client then blocks the broadcaster for everyone.

```go
// bad
frames <- frame

// good
select {
case frames <- frame:
default:
    dropped.Add(1) // client too slow, drop the frame
}
```

### CON-006 Every goroutine has an owner that stops it

- **Severity:** should
- **Principle:** P3, P6
- **Check:** long-running goroutines (pollers, tickers, consumers) that do not exit on `ctx.Done()` or a stop channel, or that are not waited for during shutdown.

Use `errgroup.WithContext` or a `sync.WaitGroup` owned by the component that starts them, and cancel on shutdown. `time.Ticker` instead of a scheduler library for a fixed interval.

```go
func (h *Hub) Run(ctx context.Context) error {
    ticker := time.NewTicker(10 * time.Second)
    defer ticker.Stop()
    for {
        select {
        case <-ctx.Done():
            return nil
        case <-ticker.C:
            h.ping()
        }
    }
}
```

### CON-007 Bound concurrency for fan-out

- **Severity:** should
- **Principle:** P6
- **Check:** a goroutine started per item of an unbounded input (per row, per request item, per file) without a limit.

```go
group, ctx := errgroup.WithContext(ctx)
group.SetLimit(8)
for _, item := range items {
    group.Go(recovering(func() error { return process(ctx, item) }))
}
return group.Wait()
```
