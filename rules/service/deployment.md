# Deployment (`DEP`)

Profile: service

### DEP-001 Ship one static binary with the frontend embedded

- **Severity:** should
- **Principle:** P10
- **Check:** frontend and backend deployed as separate artifacts for one app without a reason; `CGO_ENABLED=1` without a dependency that needs it.

The web module embeds the built SPA with `//go:embed all:html` and has two modes:

| Mode | Config | Behavior |
|------|--------|----------|
| static | `STATIC_HOSTING=true` | serves embedded files, unknown paths return `index.html`, long cache headers outside dev mode |
| dev proxy | `STATIC_HOSTING=false` | reverse-proxies to the frontend dev server |

### DEP-002 Multi-stage build with cacheable dependency layers

- **Severity:** should
- **Principle:** P10
- **Check:** source copied before `go mod download` / `bun install`, so every code change re-downloads dependencies; one stage doing everything.

```dockerfile
FROM oven/bun:1 AS ui
WORKDIR /src
COPY ui/package.json ui/bun.lock ./
RUN bun install --frozen-lockfile
COPY ui/ ./
RUN bun run build

FROM golang:1.26 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY cmd/ cmd/
COPY internal/ internal/
COPY --from=ui /src/dist/spa internal/web/html
ARG VERSION=dev
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w -X main.version=${VERSION}" -o /out/server ./cmd/server

FROM gcr.io/distroless/static-debian13:nonroot
COPY --from=build /out/server /server
USER 65532:65532 # distroless nonroot, numeric so runAsNonRoot can verify it
ENTRYPOINT ["/server"]
```

The full version with cross-compilation, digest-pinned bases and a build cache mount is [templates/service/docker/server.Dockerfile](../../templates/service/docker/server.Dockerfile).

`-s -w` strips the symbol table and DWARF. Panic stack traces still show functions and lines (they come from the runtime's own tables); what you lose is debugger support, which a production image does not need.

### DEP-003 Run as non-root on a minimal runtime image

- **Severity:** must
- **Principle:** P10
- **Check:** runtime stage running as root; a full OS image (`debian`, `ubuntu`, `golang`) as the runtime stage; `USER` given by name instead of a numeric UID (Kubernetes `runAsNonRoot` cannot verify a name and refuses to start the pod).

Default to `distroless/static:nonroot`: no shell, no package manager. Use Alpine only when the service needs a shell or system tools at runtime, and still with a non-root user.

### DEP-004 Pin base images and the Go version

- **Severity:** should
- **Principle:** P10
- **Check:** `:latest` tags in a Dockerfile; builder Go version different from `go.mod` (TCH-001).

### DEP-005 Inject the version at build time

- **Severity:** should
- **Principle:** P7
- **Check:** no way to tell from a running service which version it is.

Set `main.version` with `-ldflags -X`, log it at startup and add it to every wide event.

### DEP-006 One Dockerfile per executable, named after it

- **Severity:** should
- **Principle:** P1
- **Check:** Dockerfiles scattered or named generically when the repo builds more than one executable.

`docker/server.Dockerfile`, `docker/migrate.Dockerfile`, matching `cmd/server`, `cmd/migrate`.

### DEP-007 Configuration only through the environment

- **Severity:** must
- **Principle:** P10
- **Check:** environment-specific values or secrets baked into the image (`COPY .env`, `ENV DATABASE_PASSWORD=...`).

The same image runs in every environment; the environment differs. See CFG-001.

### DEP-008 Set `GOMEMLIMIT` from the memory limit and know where `GOMAXPROCS` comes from

- **Severity:** should
- **Principle:** P6, P10
- **Check:** where the repo contains its deployment manifests or chart: a memory limit without `GOMEMLIMIT`; a pod without a CPU limit that does not set `GOMAXPROCS`; `go.uber.org/automaxprocs` in a module whose `go` directive is 1.25 or later.

Go does not read the container memory limit. With the default `GOGC` the heap can grow to about twice the live heap before a collection, and the kernel OOM-kills the pod first. Set `GOMEMLIMIT` 5-10% below the limit; it is a soft limit, so a limit near the real working set trades the OOM for GC thrashing. Since Go 1.25 the runtime sets `GOMAXPROCS` from the CPU limit itself, which makes `automaxprocs` redundant. Without a CPU limit it still uses the node's core count, so set it from the CPU request.

```yaml
resources:
  requests: { cpu: "1", memory: 512Mi }
  limits: { memory: 512Mi }
env:
  - name: GOMEMLIMIT
    value: 460MiB # ~90% of the memory limit
  - name: GOMAXPROCS
    valueFrom:
      resourceFieldRef: { resource: requests.cpu, divisor: "1" } # rounds up to whole cores
```

Alert on container RSS, not only on Go heap metrics: memory outside the heap does not show up there.
