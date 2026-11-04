# Observability (`OBS`)

Profile: service. Logging, metrics and tracing have their own files: [logging.md](logging.md), [metrics.md](metrics.md), [tracing.md](tracing.md).

### OBS-001 Trace across service boundaries with OpenTelemetry

- **Status:** deprecated (04.11.2026, replaced by the TRC rules in [tracing.md](tracing.md): TRC-001 when to trace, TRC-007 the instrumentations, TRC-009 the flush, TRC-005 the trace ID on the wide event)

### OBS-002 Know which version is running

- **Severity:** should
- **Principle:** P7
- **Check:** no version reported at startup or on the wide event.

See DEP-005: inject the version at build time, log it at startup, add it to every wide event with a pre-enricher.

### OBS-003 Serve profiling endpoints only on an internal listener

- **Severity:** must
- **Principle:** P6
- **Check:** `import _ "net/http/pprof"` in a binary that serves `http.DefaultServeMux` (a nil `Handler`) on the public port; pprof or `expvar` routes registered on the public Gin router.

The pprof handlers expose the command line, goroutine stacks and heap contents, and let anyone start CPU profiles that load the process. The blank import registers them on `http.DefaultServeMux` as a side effect (gosec G108).

```go
// bad
import _ "net/http/pprof"
router.Any("/debug/pprof/*path", gin.WrapH(http.DefaultServeMux))

// good: a separate server, bound to localhost or reached via kubectl port-forward.
// Importing net/http/pprof still registers on DefaultServeMux, so never serve DefaultServeMux publicly.
profilingRoutes := http.NewServeMux()
profilingRoutes.HandleFunc("/debug/pprof/", pprof.Index)
profilingRoutes.HandleFunc("/debug/pprof/profile", pprof.Profile)
profilingServer := &http.Server{Addr: "127.0.0.1:6060", Handler: profilingRoutes, ReadHeaderTimeout: 5 * time.Second}
```
