# Libraries (`LIB`)

Profile: library. A library is imported by other modules, so its API is a contract. Breaking it breaks every consumer.

### LIB-001 Version with semver, major versions in the module path

- **Severity:** must
- **Principle:** P8
- **Check:** releases without a `vX.Y.Z` tag; a breaking change to an exported API released as a minor or patch; a `v2+` tag without the `/v2` suffix in the module path.

Go's module system relies on it: consumers on `v1` must never get a breaking change from `go get -u`.

### LIB-002 Keep the public API small

- **Severity:** should
- **Principle:** P1, P8
- **Check:** exported helpers, types or fields that are implementation detail; no `internal/` package in a library with more than a handful of files.

Every exported name is a promise. Start unexported and export on demand.

### LIB-003 A library does not log on its own

- **Severity:** must
- **Principle:** P3, P4
- **Check:** writes to stdout/stderr, `fmt.Print*`, the global zerolog or `log` logger, or `slog.Default()` from library code.

Return errors and let the application decide. If the library must report something that is not an error (a retry, a cache eviction), accept a logger or callback in its options and stay silent when none is given.

```go
// bad
log.Warn().Err(err).Msg("cache: redis unreachable, falling back")

// good
type Options struct {
    Logger *slog.Logger // optional; nil disables logging
}
```

### LIB-004 No hidden side effects at import or construction

- **Severity:** must
- **Principle:** P3
- **Check:** a library that reads environment variables, files or flags, starts goroutines, or registers global handlers without the caller asking for it explicitly.

A library whose purpose is reading configuration (`govengers/config`) does so only in its documented load function.

### LIB-005 Document every exported identifier

- **Severity:** must
- **Principle:** P1
- **Check:** a package without a package comment; exported types, functions, methods or constants without a doc comment starting with their name.

State concurrency safety and ownership where it is not obvious: "safe for concurrent use", "the caller must close the returned reader".

```go
// Cache is a typed LRU cache with per-entry TTL. It is safe for concurrent use.
type Cache[K comparable, V any] struct { ... }
```

### LIB-006 Show usage with runnable examples

- **Severity:** should
- **Principle:** P1, P9
- **Check:** the main entry points (`New`, the primary method) have no `Example*` function in a `_test.go` file.

Examples are compiled and, with an `// Output:` comment, run by `go test`. They cannot drift from the code the way README snippets do.

### LIB-007 Keep dependencies minimal and framework adapters separate

- **Severity:** should
- **Principle:** P2
- **Check:** a framework (Gin, a specific logger, a specific database driver) imported by the core package when only one integration point needs it.

Consumers inherit every dependency. The core package works on `net/http` and `context.Context`; framework integration lives in a subpackage named `<framework>adapter` (`authentication/ginadapter`), so the package name does not collide with the framework's own. Inside a library the service layering applies in small (ARC-001): the adapter is the transport, the core holds the logic, and persistence sits behind a storage interface the core declares and the consumer implements.

### LIB-008 Ship a LICENSE and a README at the tagged version

- **Severity:** must
- **Principle:** P10
- **Check:** no `LICENSE` file at the repo root in the latest tag; README without an install line and a minimal working example.

License scanners (`go-licenses`) read the license from the pinned tag, not from `main`. A license added after the last tag is invisible until the next release.

### LIB-009 Record breaking changes in the release notes

- **Severity:** should
- **Principle:** P7
- **Check:** a major release without notes listing what broke and how to migrate.

### LIB-010 Wrap a dependency's error with `%w` only if it is part of your API

- **Severity:** should
- **Principle:** P4, P8
- **Check:** an exported function that returns a dependency's error wrapped with `%w` (`pgconn.PgError`, a `redis` error, an HTTP client error) where the library does not document that callers may match on it.

A wrapped error becomes part of the contract: callers start matching on it with `errors.Is`, and swapping the dependency becomes a breaking change (LIB-001). Translate to the library's own sentinel (ERR-005), or keep the message and drop the chain with `%v`. Inside a module, ERR-004 still applies.

```go
// bad: consumers now depend on redis.Nil
return fmt.Errorf("cache get %s: %w", key, err)

// good
if errors.Is(err, redis.Nil) {
    return ErrMiss
}
return fmt.Errorf("cache get %s: %v", key, err)
```
