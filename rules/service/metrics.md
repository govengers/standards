# Metrics (`MET`)

Profile: service. Library: `github.com/prometheus/client_golang`.

Metrics and wide events answer different questions. Metrics are cheap aggregates for dashboards and alerts: how many requests, how many failed, how slow, how full. The wide event (LOG) holds the detail of one unit of work. A service without request metrics cannot say its own error rate or p95 latency, and every alert has to be built on log queries instead.

### MET-001 Serve `/metrics` on an internal listener

- **Severity:** must
- **Principle:** P6
- **Check:** a `/metrics` route on the public router or the public port; metrics served from `http.DefaultServeMux`; a metrics server without timeouts (LAY-006) or without shutdown (LAY-003).

Metrics reveal route names, dependency names, error rates and traffic patterns, and scraping costs CPU. Serve them from their own `http.Server` on a separate port (`:9090`) that the Service exposes to Prometheus and the Ingress never routes. Unlike profiling (OBS-003), the listener binds to all interfaces, because Prometheus scrapes it from inside the cluster.

```go
metricsServer := &http.Server{
    Addr:              ":9090",
    Handler:           promhttp.HandlerFor(metricsRegistry, promhttp.HandlerOpts{Registry: metricsRegistry}),
    ReadHeaderTimeout: 5 * time.Second,
}
```

### MET-002 Register on an own registry built in `main`

- **Severity:** must
- **Principle:** P3, P9
- **Check:** `prometheus.MustRegister`, `prometheus.DefaultRegisterer` or `promauto` without `promauto.With(registerer)` in application code; metric variables at package level; a component that creates its own registry instead of receiving a `prometheus.Registerer` through its options.

The default registry is global state (DES-003): tests that build a component twice panic with "duplicate metrics collector registration", and what a binary exports depends on which packages it imports. `main` builds one registry, registers the runtime collectors explicitly and hands a `prometheus.Registerer` to every component that has metrics (DES-001). Each component creates its collectors in its constructor and returns the registration error.

```go
// bad
var requestsTotal = promauto.NewCounterVec(prometheus.CounterOpts{Name: "requests_total"}, []string{"route"})

// good, in main
metricsRegistry := prometheus.NewRegistry()
metricsRegistry.MustRegister(
    collectors.NewGoCollector(),
    collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}),
    collectors.NewBuildInfoCollector(),
)
httpMetrics, err := server.NewHTTPMetrics(&server.HTTPMetricsOptions{Namespace: "billing", Registerer: metricsRegistry})
```

`MustRegister` is fine in `main`, where a duplicate is a startup programming error (ERR-001).

### MET-003 Record rate, errors and duration of every request

- **Severity:** must
- **Principle:** P7
- **Check:** a service without a request counter labeled by route template, method and status, a request duration histogram and an in-flight gauge; HTTP routes not covered by the middleware.

These three answer the first questions of every incident: is traffic normal, what fails, what is slow. Record them once, in a middleware (or interceptor for RPC), so no handler can forget them.

```go
// Middleware records every request under its route template, never under the raw path.
func (m *HTTPMetrics) Middleware() gin.HandlerFunc {
    return func(ginContext *gin.Context) {
        start := time.Now()
        m.inFlight.Inc()
        defer m.inFlight.Dec()

        ginContext.Next()

        route := ginContext.FullPath() // "/api/v1/products/:id"; empty when no route matched
        if route == "" {
            route = "unmatched"
        }
        method := methodLabel(ginContext.Request.Method)
        m.requests.WithLabelValues(route, method, strconv.Itoa(ginContext.Writer.Status())).Inc()
        m.durations.WithLabelValues(route, method).Observe(time.Since(start).Seconds())
    }
}

// methodLabel bounds the method label to the methods the API serves (MET-004).
func methodLabel(method string) string {
    switch method {
    case http.MethodGet, http.MethodPost, http.MethodPut, http.MethodPatch, http.MethodDelete, http.MethodHead, http.MethodOptions:
        return method
    default:
        return "other"
    }
}
```

Pick histogram buckets around the latency objective (`prometheus.DefBuckets` covers 5 ms to 10 s). Exclude `/api/health` like LOG-010 does.

### MET-004 Keep label values to small, closed sets

- **Severity:** must
- **Principle:** P6
- **Check:** a label whose value comes from request data or identifiers: raw URL path, user, tenant, object or request IDs, email, error message, query string, client-supplied header or method without bounding.

Every distinct label combination is a time series that Prometheus keeps in memory. One label fed by IDs or raw paths creates a series per value; a client scanning URLs can grow the series count until Prometheus runs out of memory, for every service it scrapes. Labels come from sets the code defines: route templates, a bounded method set, status codes, outcome (`success`, `failure`), queue and dependency names. Per-object detail goes on the wide event.

```go
// bad: one series per product and per URL
m.requests.WithLabelValues(ginContext.Request.URL.Path, productID.String()).Inc()

// good
m.requests.WithLabelValues(ginContext.FullPath(), methodLabel(ginContext.Request.Method), strconv.Itoa(status)).Inc()
```

### MET-005 Follow the Prometheus naming conventions

- **Severity:** should
- **Principle:** P1, P8
- **Check:** metric names that are not `<namespace>_<subsystem>_<name>_<unit>` in snake_case; durations not in seconds or sizes not in bytes; a counter without `_total`; a gauge or histogram with `_total`; a metric without `Help`; names reported by `testutil.CollectAndLint`.

The namespace is the service name, the subsystem the component (`http`, `db`, `queue`, `cache`, `client_<system>`). Base units (`_seconds`, `_bytes`) let dashboards and recording rules combine metrics from any service.

| Kind | Example |
|------|---------|
| counter | `billing_http_requests_total` |
| histogram | `billing_http_request_duration_seconds` |
| gauge | `billing_queue_jobs_pending` |
| info | `go_build_info` (version as a label, value 1) |

### MET-006 Instrument outbound calls, the pool and background work

- **Severity:** should
- **Principle:** P6, P7
- **Check:** a client package (ARC-005) without a call counter by outcome and a duration histogram; no database pool metrics; a job queue (JOB) without pending, running, failed and duration metrics.

When a dependency slows down, its own duration histogram shows it before the request latency does. Clients and the job runner receive the `Registerer` through their options like everything else (MET-002). Export pool statistics with a collector that reads `pgxpool.Pool.Stat()` at scrape time instead of updating gauges on every acquire.

```go
callDurations := prometheus.NewHistogramVec(prometheus.HistogramOpts{
    Namespace: options.Namespace, Subsystem: "client_openrouter", Name: "request_duration_seconds",
    Help: "OpenRouter request duration by operation and outcome.",
}, []string{"operation", "outcome"})
```

### MET-007 Every metric with an alert or dashboard has a test

- **Severity:** should
- **Principle:** P8, P9
- **Check:** a counter or histogram that an alert rule or dashboard uses without a test that asserts it moves; no `testutil.CollectAndLint` over the component's collectors.

A renamed label or a counter that is never incremented breaks the alert silently. Build the component with a fresh `prometheus.NewRegistry()` in the test and assert with `prometheus/testutil`.

```go
func TestFailedCheckoutIsCounted(t *testing.T) {
    metricsRegistry := prometheus.NewRegistry()
    checkoutService, err := service.NewCheckoutService(&service.CheckoutServiceOptions{Registerer: metricsRegistry, ...})
    require.NoError(t, err)

    _, err = checkoutService.Checkout(t.Context(), declinedCard)

    require.Error(t, err)
    require.Equal(t, 1.0, testutil.ToFloat64(checkoutService.Metrics().Failures.WithLabelValues("card_declined")))
    problems, err := testutil.CollectAndLint(checkoutService.Metrics().Failures)
    require.NoError(t, err)
    require.Empty(t, problems)
}
```

### MET-008 Ship the scrape configuration with the service

- **Severity:** should
- **Principle:** P8, P10
- **Check:** where the repo contains its deployment manifests or chart: a metrics port without a `ServiceMonitor` or `PodMonitor`; a scrape target that is not the named metrics port.

Name the container port `metrics` and select it in the `ServiceMonitor`, so the scrape follows the port and not a number. A service whose metrics nobody scrapes looks healthy until the first incident.

```yaml
endpoints:
  - port: metrics
    path: /metrics
    interval: 30s
```
