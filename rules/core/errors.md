# Errors (`ERR`)

Profile: core

### ERR-001 Return errors, never panic

- **Severity:** must
- **Principle:** P4, P6
- **Check:** `panic`, `log.Fatal` or `os.Exit` outside `main()` and startup wiring; a `Must*` helper called on runtime input (request data, DB results).

Panics take down every in-flight request. They are fine for programmer errors that cannot happen (`regexp.MustCompile` on a literal) and for fail-fast misconfiguration during startup.

```go
// bad
func (r *UserRepository) Get(ctx context.Context, id uuid.UUID) *model.User {
    row, err := r.queries.GetUser(ctx, id)
    if err != nil {
        panic(err)
    }
    return toUser(row)
}

// good
func (r *UserRepository) Get(ctx context.Context, id uuid.UUID) (*model.User, error) {
    row, err := r.queries.GetUser(ctx, id)
    if err != nil {
        return nil, mapError(err)
    }
    return toUser(row), nil
}
```

### ERR-002 Match errors by identity, never by string

- **Severity:** must
- **Principle:** P4, P8
- **Check:** `err.Error()` compared with `==`, `strings.Contains` or a regex; `err == ErrX` instead of `errors.Is` for an error that may be wrapped; type assertion `err.(*T)` instead of `errors.As`.

Error messages are not an API; wrapping breaks `==`.

```go
// bad
if strings.Contains(err.Error(), "no rows") { ... }
if err == ErrNotFound { ... }

// good
if errors.Is(err, model.ErrNotFound) { ... }
var postgresError *pgconn.PgError
if errors.As(err, &postgresError) && postgresError.Code == "23505" { ... }
```

### ERR-003 Handle and log an error exactly once

- **Severity:** must
- **Principle:** P4, P7
- **Check:** an error that is logged and then also returned; the same error logged at more than one layer; a repository or library that logs instead of returning.

Log-and-return produces the same failure three times in the logs with different context. The layer that decides what happens (the controller, the job runner, `main`) records it; everything below returns. In services "logging" means recording on the wide event ([LOG-002](../service/logging.md#log-002-every-failure-ends-up-in-the-wide-event)); a failure handled locally instead of returned is recorded where it is handled.

```go
// bad
func (r *ProductRepository) Get(ctx context.Context, id uuid.UUID) (*model.Product, error) {
    row, err := r.queries.GetProduct(ctx, id)
    if err != nil {
        log.Error().Err(err).Msg("error getting product")
        return nil, err
    }
    return toProduct(row), nil
}

// good: the repository returns, the controller decides and records it on the wide event (LOG-002)
func (r *ProductRepository) Get(ctx context.Context, id uuid.UUID) (*model.Product, error) {
    row, err := r.queries.GetProduct(ctx, id)
    if err != nil {
        return nil, fmt.Errorf("get product %s: %w", id, mapError(err))
    }
    return toProduct(row), nil
}
```

### ERR-004 Wrap errors with context when crossing a layer

- **Severity:** should
- **Principle:** P4, P7
- **Check:** `return err` of an error from another package where the current function knows something the caller does not (the ID, the operation); wrapping with `%v` instead of `%w`.

`%w` keeps `errors.Is` working; the message tells the reader which operation on which object failed. Do not wrap with a message that only repeats the function name chain (`"failed to x: failed to y"`); say what was being done.

```go
// bad
return nil, err
return nil, fmt.Errorf("error: %v", err)

// good
return nil, fmt.Errorf("load settings for business %s: %w", businessID, err)
```

### ERR-005 Define sentinel errors for conditions callers branch on

- **Severity:** should
- **Principle:** P4, P8
- **Check:** callers that need to distinguish "not found", "conflict", "invalid" or "permission denied" have to import a driver package (`pgx`, `pgconn`), import a lower layer they do not otherwise use, or parse messages to do so.

In a service, the shared conditions live in `internal/model`, so the repository produces them, the service adds its own, and the controller matches them without importing the layer below (ARC-002). A library owns its sentinels in its own package (LIB-010).

```go
// bad: the controller knows about pgx
if errors.Is(err, pgx.ErrNoRows) { ginContext.AbortWithStatus(http.StatusNotFound) }

// good: internal/model/errors.go
var (
    ErrNotFound         = errors.New("not found")
    ErrConflict         = errors.New("conflict")
    ErrInvalid          = errors.New("invalid")
    ErrPermissionDenied = errors.New("permission denied")
)

// the repository maps pgx.ErrNoRows to model.ErrNotFound (DAT-004); the controller maps it to 404 (API-002)
if errors.Is(err, model.ErrNotFound) { ... }
```

### ERR-006 Never discard an error silently

- **Severity:** must
- **Principle:** P4
- **Check:** `_ =` or `_, _ =` on a call returning an error, or an error-returning call used as a statement, without a comment saying why ignoring it is safe; `strconv.Atoi` results whose error is dropped on user input; `defer file.Close()` on a file or writer that was written to.

`errcheck` catches most cases; this rule covers the explicit `_` that lint lets through, and `Close`, which the lint baseline deliberately does not check. For a written file, `Close` is where buffered data is flushed, so its error is the write error.

```go
// bad: a failed flush is lost and the caller reports success
file, err := os.Create(path)
if err != nil {
    return err
}
defer file.Close()
_, err = file.Write(data)
return err

// good: named result err
defer func() {
    if closeError := file.Close(); closeError != nil && err == nil {
        err = fmt.Errorf("close %s: %w", path, closeError)
    }
}()
```

```go
// bad
limit, _ := strconv.Atoi(ginContext.Query("limit"))

// good
limit, err := strconv.Atoi(ginContext.DefaultQuery("limit", "100"))
if err != nil {
    return model.Pagination{}, fmt.Errorf("limit %q: %w", ginContext.Query("limit"), model.ErrInvalid)
}

// good: documented
_ = response.Body.Close() // read-only response, close error carries no information
```

### ERR-007 Background work reports its failure

- **Severity:** must
- **Principle:** P4, P7
- **Check:** a goroutine or job whose error or panic is neither logged, recorded in shared state, nor returned through a channel or errgroup.

A background task that dies silently leaves the UI stuck at "processing" forever. See [CON-001](concurrency.md#con-001-recover-panics-in-every-goroutine-you-start) for the panic side.

```go
// bad
go func() { _ = doWork(ctx) }()

// good
safeGo(func() {
    defer progress.SetRunning(false)
    if err := doWork(ctx); err != nil {
        progress.SetError(err)
    }
})
```

### ERR-008 Return a literal `nil` error, never a typed nil pointer

- **Severity:** must
- **Principle:** P4
- **Check:** a function with result type `error` (or an interface) that returns a variable of a concrete pointer type (`*ValidationError`) that can be nil.

An interface holding a typed nil pointer is not equal to `nil`, so the caller sees a failure that never happened.

```go
// bad: err != nil is always true for the caller
func validate(user User) error {
    var validationError *ValidationError
    if user.Name == "" {
        validationError = &ValidationError{Field: "name"}
    }
    return validationError
}

// good
func validate(user User) error {
    if user.Name == "" {
        return &ValidationError{Field: "name"}
    }
    return nil
}
```

### ERR-009 Never return a nil value together with a nil error

- **Severity:** must
- **Principle:** P4
- **Check:** enforced by `nilnil` in [.golangci.yml](../../.golangci.yml): `return nil, nil` from a function returning a pointer, interface, function or channel with an error.

A caller that checked `err` dereferences the value and panics. "Nothing there" is a condition the caller branches on, so it is a sentinel error (ERR-005), or a `bool` result when absence is normal (`Get(key) (V, bool)`).

```go
// bad
if errors.Is(err, pgx.ErrNoRows) {
    return nil, nil
}

// good
if errors.Is(err, pgx.ErrNoRows) {
    return nil, fmt.Errorf("user %s: %w", id, model.ErrNotFound)
}
```
