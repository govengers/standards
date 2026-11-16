# Layout and bootstrap (`LAY`)

Profile: service

### LAY-001 Follow the standard directory layout

- **Severity:** should
- **Principle:** P1, P8
- **Check:** application code outside `internal/`; more than `main.go` in a `cmd/<name>/` directory, other than the composition file of a template application (`domain.go`, see `playbooks/deriving-an-application.md`); generated query code importable from outside the repository package; ad-hoc top-level directories for what has a standard place.

```
cmd/server/main.go          entry point: reads configuration, wires every component (LAY-002)
cmd/migrate/main.go         runs migrations against DATABASE_URL
cmd/generate/main.go        writes the API clients from the livewire registry (a service that ships clients)
cmd/<name>/main.go          the generated CLI, named after the service (a service that ships clients)
internal/
  controller/               transport: one controller per business object and transport (ARC-001)
  service/                  business logic: one service per business object
  repository/               persistence: one repository per business object
    queries/*.sql           sqlc input
    internal/sqlc/          sqlc output, committed, private to the repository layer
  client/<system>/          one package per external system
  model/                    domain types and domain errors, imported by every layer
  server/                   http.Server, router, middleware, lifecycle; mounts the controllers
  actor/                    the acting user in the context (AUTH-006)
  authentication/           auth library wiring (its storage adapter lives in repository/, ARC-002)
  authorization/            composable permission checkers
  database/                 pool, goose migrations (migrations/*.sql), Migrate()
  event/                    event types + WebSocket hub
  web/                      embedded frontend (DEP-001)
  testdatabase/             per-test database helper
pkg/                        for other modules: the API's payload types and the generated clients
  api/                      request and response types, imported by the controllers and the clients
  apiclient/                generated Go client, committed
  command/                  generated CLI commands, committed
openapi.yaml                generated OpenAPI document, committed; openapi-check diffs it against main
test/e2e/                   end-to-end suite against the built binary (TST-011)
docker/server.Dockerfile    one Dockerfile per executable
hack/                       dev helper scripts
sandbox/                    scratch output, gitignored
sqlc.yaml
justfile
```

`cmd/<name>` matches the executable (`cmd/server`, `cmd/controller`). Use `pkg/` only for code meant to be imported by other modules: the API's payload types and the clients generated from them, so another service, an agent or a test calls the API through the same types the server decodes. Anything else meant for other modules (a reusable component, a protocol) belongs in its own library repo. The generated files are committed and checked by `just generate-check` (TCH-003); the coverage gate excludes `pkg/`.

### LAY-002 Bootstrap in `main()` in a fixed, visible order

- **Severity:** must
- **Principle:** P3, P6
- **Check:** layers wired implicitly (package-level initialization, `init()`, lazy singletons); components built anywhere but `main` (ARC-006); serving traffic before migrations ran or config was validated.

```
Config -> Logging -> Tracing -> Metrics registry -> Database pool -> Migrate -> Repositories -> Clients -> Event hub -> Services -> Controllers -> Server + metrics server -> Run
```

`run()` lists the steps; one function per layer in `main.go` builds that layer's components and copies configuration values into their options (FUN-003, CFG-006).

```go
func main() {
    if err := run(); err != nil {
        log.Fatal().Err(err).Msg("startup failed")
    }
}

func run() error {
    ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
    defer stop()

    configuration, err := loadConfiguration() // CFG-001: every value, validated, before anything else
    if err != nil {
        return err
    }
    config.Print()

    pool, err := openDatabase(ctx, configuration) // database.NewPool, then database.Migrate
    if err != nil {
        return err
    }
    defer pool.Close()

    repositories, err := newRepositories(pool)
    if err != nil {
        return err
    }
    eventHub, err := event.NewHub(&event.HubOptions{UserProvider: repositories.user})
    if err != nil {
        return err
    }
    services, err := newServices(configuration, repositories, eventHub)
    if err != nil {
        return err
    }
    apiServer, err := newServer(configuration, services, eventHub)
    if err != nil {
        return err
    }

    return serveUntilShutdown(ctx, apiServer, eventHub)
}

// serveUntilShutdown stops the server before the hub, so broadcasts from requests that are
// still draining reach their clients (LAY-003).
func serveUntilShutdown(ctx context.Context, apiServer *server.Server, eventHub *event.Hub) error {
    serverContext, stopServer := context.WithCancel(ctx)
    defer stopServer()
    hubContext, stopHub := context.WithCancel(context.WithoutCancel(ctx))
    hubDone := make(chan error, 1)
    go func() {
        hubDone <- recovering(func() error { return eventHub.Run(hubContext) })()
        stopServer() // a hub that dies takes the server down with it
    }()

    serveError := apiServer.Run(serverContext) // returns after the drain and the WebSocket close
    stopHub()
    return errors.Join(serveError, <-hubDone)
}

func newServices(configuration *Configuration, repositories *repositorySet, eventHub *event.Hub) (*serviceSet, error) {
    productService, err := service.NewProductService(&service.ProductServiceOptions{
        ProductRepository: repositories.product,
        Broadcaster:       eventHub,
        MaximumPriceCents: int64(configuration.ProductMaximumPriceCents),
    })
    if err != nil {
        return nil, err
    }
    return &serviceSet{product: productService}, nil
}
```

`run() error` keeps `main` to the one place that exits and lets deferred cleanup run on error. `recovering` is CON-001's panic wrapper.

### LAY-003 Shut down gracefully on SIGTERM

- **Severity:** must
- **Principle:** P6
- **Check:** no signal handling; `http.Server.ListenAndServe` without a `Shutdown(ctx)` path; `Run` returning as soon as `ListenAndServe` returns `http.ErrServerClosed` instead of waiting for `Shutdown` to finish; a shutdown timeout not shorter than the pod's `terminationGracePeriodSeconds`; WebSocket connections not closed on shutdown; background workers not stopped and awaited before the pool closes.

Kubernetes sends SIGTERM and waits the grace period. In-flight requests and jobs should finish, then the process exits. Three traps:

- `ListenAndServe` returns `ErrServerClosed` the moment `Shutdown` starts. If `Run` returns then, deferred cleanup closes the pool under requests that are still running.
- Load balancers keep routing to the pod for a few seconds after SIGTERM. Fail readiness first and keep serving briefly, otherwise every rollout produces a burst of 502s.
- `Shutdown` neither closes nor waits for hijacked connections (WebSockets). Close them yourself and wait for that; `RegisterOnShutdown` runs its callbacks in goroutines and `Shutdown` does not wait for them.

```go
// bad: Run returns on ErrServerClosed while Shutdown is still draining
go func() {
    <-ctx.Done()
    _ = httpServer.Shutdown(context.Background())
}()
return httpServer.ListenAndServe()

// good
func (s *Server) Run(ctx context.Context) error {
    serveErrors := make(chan error, 1)
    go func() { serveErrors <- recovering(s.httpServer.ListenAndServe)() }()

    select {
    case err := <-serveErrors:
        return err // failed to start
    case <-ctx.Done():
    }

    s.options.Health.SetDraining() // readiness now answers 503 draining (LAY-004)
    time.Sleep(5 * time.Second) // let endpoints and load balancers drop the pod

    shutdownContext, cancel := context.WithTimeout(context.Background(), 20*time.Second) // below the 30 s grace period
    defer cancel()
    shutdownError := s.httpServer.Shutdown(shutdownContext) // drains HTTP requests; ignores hijacked WebSockets
    if shutdownError != nil {
        shutdownError = errors.Join(shutdownError, s.httpServer.Close())
    }
    s.options.Hub.CloseAll(shutdownContext) // after the drain, so broadcasts of draining requests still go out
    return shutdownError
}
```

### LAY-004 Expose liveness and readiness

- **Severity:** should
- **Principle:** P6
- **Check:** no health endpoint; probes written by hand instead of `github.com/govengers/telemetry/health`; a readiness check that does not cover the database; a liveness probe that looks at a dependency; health routes behind authentication or counted in request metrics, wide events or traces.

`health.New` takes the readiness checks by name (a pool ping, a Redis ping), runs them concurrently under one timeout below the probe's, caches the result for a second and answers 503 when one fails or after `SetDraining` (LAY-003). The body names each check's status, never an error text; `OnCheckFailure` gives `main` the reason. Liveness (`health.LivenessRoute`, `GET /api/health`) answers 200 while the process serves HTTP and never looks at a dependency, so a database outage does not restart every pod. Readiness is `health.ReadinessRoute`, `GET /api/ready`. Both are skipped by the request metrics, the wide events and the traces.

```go
probes, err := health.New(&health.Options{
    Checks:         map[string]health.Check{"database": pool.Ping},
    OnCheckFailure: recordUnready, // a wide event per failure, never blocking
})
if err != nil {
    return fmt.Errorf("create health probes: %w", err)
}
ginadapter.RegisterHealthRoutes(engine, probes) // telemetry/ginadapter, before the UI (API-010)
```

### LAY-005 A fresh checkout builds and tests with one command

- **Severity:** should
- **Principle:** P8, P9
- **Check:** `go build ./...`, `go generate ./...` and `go test -race ./...` fail on a fresh clone with the documented dev setup; README without the dev setup steps.

### LAY-006 Serve with an explicit `http.Server` that has timeouts

- **Severity:** must
- **Principle:** P6
- **Check:** `router.Run(...)` (Gin), `http.ListenAndServe` or `http.ListenAndServeTLS` in a service; an `http.Server` without `ReadHeaderTimeout`; no `IdleTimeout` and no `ReadTimeout` on a server facing clients.

Every zero timeout on `http.Server` means "no timeout". Slow or idle clients then hold goroutines and file descriptors until the process runs out of them ("accept: too many open files"). `router.Run` and the package-level `ListenAndServe` cannot set timeouts at all. `gosec` flags `ListenAndServe` (G114) and a missing `ReadHeaderTimeout` (G112); this rule also covers Gin's `Run`.

```go
// bad
return router.Run(":8080")

// good
s.httpServer = &http.Server{
    Addr:              ":8080",
    Handler:           router,
    ReadHeaderTimeout: 10 * time.Second,
    ReadTimeout:       30 * time.Second,
    WriteTimeout:      60 * time.Second,
    IdleTimeout:       120 * time.Second,
}
```

`WriteTimeout` cuts long responses. For SSE or large downloads, extend the deadline on that route with `http.NewResponseController(w).SetWriteDeadline` instead of dropping it for the whole server. Request body size is API-005.
