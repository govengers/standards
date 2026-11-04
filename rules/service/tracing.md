# Tracing (`TRC`)

Profile: service. Library: `github.com/govengers/telemetry/tracing` on the OpenTelemetry Go SDK, with the OpenTelemetry contrib instrumentations (`otelgin`, `otelhttp`, `otelpgx`, `redisotel`).

One tool owns each signal: wide events are the logs (LOG), Prometheus is the metrics (MET), OpenTelemetry is used for traces only. A trace answers the one question the other two cannot: which service, and which call inside it, made this request slow or failed it. The signals meet on the wide event, whose `trace.id` leads from a log line to its trace.

### TRC-001 Trace a service that crosses a service boundary

- **Severity:** should
- **Principle:** P7
- **Check:** a service that calls another service over the network, or is called by one through a proxy or gateway that traces, and builds no tracer provider; tracing added to a single binary only for its own database calls.

A request that crosses a boundary can only be followed end to end through a propagated trace. Inside one binary the wide event already records every interaction (`db.*`, `cache.*`, `http.*`, LOG-004), so tracing a service that only talks to its own Postgres adds a pipeline and buys nothing.

```go
// in main, after the configuration (LAY-002)
traces, err := tracing.New(ctx, &tracing.Options{ServiceName: "billing", ServiceVersion: version})
if err != nil {
    return err
}
otel.SetTracerProvider(traces.TracerProvider())
otel.SetTextMapPropagator(propagation.TraceContext{})
```

`tracing.New` sets no global state; the two `otel.Set*` lines are main's, or main passes `traces.TracerProvider()` and `propagation.TraceContext{}` to each instrumentation through its options.

### TRC-002 Configure tracing with the standard `OTEL_*` variables; no endpoint means no tracing

- **Severity:** should
- **Principle:** P3, P6
- **Check:** an exporter endpoint, headers, protocol or sampler read from the service's own configuration (`config.String("TRACING_ENDPOINT")`) or hard-coded; a tracer provider built by hand instead of `tracing.New`; a boot that fails or logs errors because no collector is configured.

Every collector deployment, Helm chart and operator speaks `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_EXPORTER_OTLP_HEADERS`, `OTEL_RESOURCE_ATTRIBUTES` and `OTEL_TRACES_SAMPLER`; a second set of names drifts from them. `tracing.New` returns a no-op provider when neither `OTEL_EXPORTER_OTLP_ENDPOINT` nor `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` is set (or with `OTEL_SDK_DISABLED=true`, `OTEL_TRACES_EXPORTER=none`), so a deployment without a trace backend pays nothing. A protocol it cannot export (`grpc`) fails the boot instead of losing every span.

```go
// bad
config.String("JAEGER_URL").Default("http://localhost:14268").Into(&configuration.jaegerURL)
exporter, err := otlptracehttp.New(ctx, otlptracehttp.WithEndpointURL(configuration.jaegerURL))

// good: the deployment sets OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.observability:4318
traces, err := tracing.New(ctx, &tracing.Options{ServiceName: "billing", ServiceVersion: version})
```

### TRC-003 Propagate the W3C trace context on every hop

- **Severity:** should
- **Principle:** P7
- **Check:** a service that traces without the `propagation.TraceContext` propagator (installed globally or passed to each instrumentation); an outbound HTTP client without `otelhttp.NewTransport`; a govengers/jobs worker and store without `oteladapter.NewPropagator()`; a custom header carrying a trace or correlation ID.

A trace is only as long as its weakest hop. The W3C `traceparent` header is what Traefik, Envoy, every OpenTelemetry SDK and every collector understand. Jobs are a hop too: the propagator stores the context with the job, so the attempt joins the trace of the request that enqueued it (JOB-010).

```go
// bad: the provider's calls start new traces
client := &http.Client{Timeout: 10 * time.Second}

// good
client := &http.Client{Timeout: 10 * time.Second, Transport: otelhttp.NewTransport(http.DefaultTransport)}
```

### TRC-004 Keep every span in the SDK and sample in the collector

- **Severity:** should
- **Principle:** P7
- **Check:** `sdktrace.WithSampler(...)` with `TraceIDRatioBased`, `NeverSample` or a custom sampler in code; `OTEL_TRACES_SAMPLER` set to a ratio in a deployment that has a collector able to tail-sample.

A head sampler decides before the request ran, so it drops the slow and failing traces in the same proportion as the boring ones, the same mistake LOG-010 forbids for wide events. Leave the SDK default, `ParentBased(AlwaysOn)`, and let the collector keep every trace with an error or above the latency objective and a fraction of the rest (tail sampling).

### TRC-005 Put `trace.id` and `trace.span_id` on every wide event

- **Severity:** should
- **Principle:** P7
- **Check:** a traced service whose wide-event middleware has no pre-enricher calling `tracing.RecordTraceID`; `otelgin.Middleware` mounted after the wide-event middleware; a job worker that traces without `oteladapter.NewMiddleware` after `wideeventadapter`; the trace ID under another key.

The keys are `trace.id` and `trace.span_id` (LOG-004, LOG-005), in every service and in jobs, so one log query finds the event of any trace. The span must exist when the event begins: `otelgin` runs first.

```go
wideEvents, err := wideeventginadapter.NewMiddleware(&wideeventginadapter.Options{
    Emitter: emitter,
    PreEnricher: func(we *wideevent.Event, ginContext *gin.Context) {
        tracing.RecordTraceID(ginContext.Request.Context(), we)
    },
})
engine.Use(recovery, otelgin.Middleware("billing"), wideEvents, requestMetrics)
```

With the propagator installed and no collector, an incoming `traceparent` still reaches the event: the request's logs carry the caller's trace ID.

### TRC-006 Name spans by template; no secrets or personal data in span names or attributes

- **Severity:** must
- **Principle:** P6
- **Check:** a span name built from a raw path, an ID, a query or user input; `redisotel.InstrumentTracing` without `redisotel.WithDBStatement(false)`; `otelpgx` with `WithIncludeQueryParameters`; `span.SetAttributes` or `span.RecordError` with tokens, passwords, session IDs, email addresses, names, request or response bodies; a tracer provider built without the query redaction of `tracing.New`.

Spans go to a trace backend that is usually shared wider and kept longer than the database, exactly like wide events (LOG-009). Span names are a dimension of the backend's index; a name per user or per ID grows it without bound, like a raw path as a metric label (MET-004). `otelgin` names spans after the route template (`GET /api/v1/invoices/:id`). The Redis instrumentation records every command with its keys and values by default, so turn the statement off. `tracing.New` replaces the query values of `url.full` and `url.query` with `redacted` before export, because `otelhttp` records outbound URLs with their query.

```go
// bad
_, span := tracer.Start(ctx, "GET "+request.URL.Path)
span.SetAttributes(attribute.String("user.email", user.Email))
err = redisotel.InstrumentTracing(redisClient)

// good
_, span := tracer.Start(ctx, "invoice.render")
span.SetAttributes(attribute.String("invoice.id", invoiceID.String()))
err = redisotel.InstrumentTracing(redisClient, redisotel.WithDBStatement(false))
```

### TRC-007 Instrument Gin, outbound HTTP, pgx and Redis with the contrib instrumentations

- **Severity:** should
- **Principle:** P2, P7
- **Check:** a traced service with a Gin engine without `otelgin.Middleware`, an outbound client without `otelhttp`, a pgx pool without `otelpgx`, a Redis client without `redisotel.InstrumentTracing`; spans for health and readiness probes; a hand-written wrapper doing what an instrumentation already does.

The instrumentations follow the semantic conventions and are maintained with the SDK; use them directly, not through own wrappers. Probes make no traces: filter them like the metrics (`SkipRoutes`) and the wide events (`SkipPaths`) do.

```go
engine.Use(otelgin.Middleware("billing", otelgin.WithGinFilter(func(ginContext *gin.Context) bool {
    return ginContext.FullPath() != "/api/health"
})))
poolConfig.ConnConfig.Tracer = otelpgx.NewTracer()
```

### TRC-008 Use OpenTelemetry for traces only

- **Severity:** should
- **Principle:** P2
- **Check:** an OpenTelemetry `MeterProvider` or `LoggerProvider` built or installed (`sdk/metric`, `sdk/log`, `otel.SetMeterProvider`, `global.SetLoggerProvider`); `redisotel.InstrumentMetrics`; the OpenTelemetry Prometheus exporter or an `otelslog` bridge; a `go.opentelemetry.io/otel/log` dependency.

Prometheus already owns the metrics (MET), with its own registry, tests and alerts; OpenTelemetry metrics need a collector in every deployment and never reach that registry. Wide events already own the logs. The OpenTelemetry log modules are still on a v0 line that breaks between minors. Without a `MeterProvider` the contrib instrumentations record no metrics, which is what we want. For Redis pool metrics use `redisprometheus.NewCollector` on the service's registry.

### TRC-009 Flush the tracer provider last in the drain

- **Severity:** should
- **Principle:** P6
- **Check:** a tracer provider that is never shut down; `Shutdown` without a deadline; `Shutdown` before the servers and the job worker drained.

The batch processor buffers spans; the ones of the requests that drained last are lost when the process exits without a flush. Shut the provider down after everything that creates spans stopped, with its own deadline inside the termination grace period (LAY-003).

```go
defer func() {
    flushContext, cancel := context.WithTimeout(context.Background(), 5*time.Second)
    defer cancel()
    if err := traces.Shutdown(flushContext); err != nil {
        logger.Error("shutdown incomplete", "error", err.Error())
    }
}()
```

### TRC-010 Bump the OpenTelemetry modules as one family

- **Severity:** should
- **Principle:** P8
- **Check:** `go.opentelemetry.io/otel`, `otel/trace`, `otel/sdk` and the OTLP exporters on different minors in one `go.mod`; a `go.opentelemetry.io/contrib` instrumentation from a release that does not match the SDK's minor.

The SDK, the API and the exporters are released together and only tested together; a partial bump compiles and then skews (or, for the v0 log modules, does not compile at all). Move them in one `go get`, with the contrib release built for that SDK, then `go mod tidy`, the tests and `govulncheck` (TCH-008). Dependabot groups help.

```sh
go get go.opentelemetry.io/otel@v1.47.0 go.opentelemetry.io/otel/trace@v1.47.0 go.opentelemetry.io/otel/sdk@v1.47.0 \
    go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp@v1.47.0 \
    go.opentelemetry.io/contrib/instrumentation/github.com/gin-gonic/gin/otelgin@v0.72.0
```
