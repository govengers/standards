# The Govengers Standards

How we write Go in the govengers org, and the source of truth a review agent measures code against.

- [MANIFESTO.md](MANIFESTO.md) - what we believe (principles `P1`-`P10`). Every rule traces back to one.
- [rules/](rules/) - what gets checked. Each rule has a stable ID, a severity and a check.
- [playbooks/](playbooks/) - step-by-step guides. Guidance, not graded.
- [AGENTS.md](AGENTS.md) - what a coding agent reads before writing Go, by task.
- [REVIEW.md](REVIEW.md) - how a review agent applies the rules.
- [skills/govengers-review/](skills/govengers-review/SKILL.md) - Claude Code skill that runs REVIEW.md with parallel review agents. Install: `ln -s "$PWD/skills/govengers-review" ~/.claude/skills/govengers-review`.
- [CONTRIBUTING.md](CONTRIBUTING.md) - how to add or change a rule.
- [.golangci.yml](.golangci.yml) - the lint baseline. Anything a linter can catch lives there, not in prose.

## Profiles

Not every rule fits every repo. A repo declares its profile in `.govengers.yml` at its root:

```yaml
profile: service        # library | service
exceptions:             # deliberate deviations, each with a reason
  - rule: DES-003
    reason: config is a process-wide registry by design
```

| Profile | Applies | Typical repo |
|---------|---------|--------------|
| `library` | `core` + `library` | `cache`, `config`, `basicauth`, `wide-event-logger` |
| `service` | `core` + `service` | an API server or controller with a `cmd/` entry point |

## Rule index

### core - every Go repo

| File | Prefix | Covers |
|------|--------|--------|
| [errors.md](rules/core/errors.md) | `ERR` | returning, wrapping, matching and logging errors |
| [naming.md](rules/core/naming.md) | `NAM` | spelled-out names, initialisms, packages, receivers |
| [functions.md](rules/core/functions.md) | `FUN` | one job, no hidden side effects, one level of abstraction, pure decisions |
| [comments.md](rules/core/comments.md) | `CMT` | names over comments, doc comments with a contract, no commented-out code |
| [design.md](rules/core/design.md) | `DES` | options pattern, no init, no globals, interfaces, encapsulation |
| [concurrency.md](rules/core/concurrency.md) | `CON` | goroutines, context, shared state, channels |
| [resilience.md](rules/core/resilience.md) | `RES` | timeouts, retries, idempotency for outbound calls |
| [testing.md](rules/core/testing.md) | `TST` | what to test per layer, coverage, end-to-end suites, tools |
| [toolchain.md](rules/core/toolchain.md) | `TCH` | Go version, modules, tools, lint, justfile |

### library - reusable modules

| File | Prefix | Covers |
|------|--------|--------|
| [library.md](rules/library/library.md) | `LIB` | API surface, dependencies, versioning, docs, side effects |

### service - deployable applications

| File | Prefix | Covers |
|------|--------|--------|
| [architecture.md](rules/service/architecture.md) | `ARC` | controller, service, repository and client layers; wiring in `main` |
| [layout.md](rules/service/layout.md) | `LAY` | directory layout, bootstrap order, server timeouts, shutdown |
| [configuration.md](rules/service/configuration.md) | `CFG` | env config read only in `main`, secrets, feature gating |
| [data-access.md](rules/service/data-access.md) | `DAT` | sqlc + pgx/v5 + goose, repository layer, check chain |
| [api.md](rules/service/api.md) | `API` | REST shape, handlers, payloads, pagination, sorting |
| [auth.md](rules/service/auth.md) | `AUTH` | authentication, composable authorization |
| [realtime.md](rules/service/realtime.md) | `RT` | WebSocket events and broadcasting |
| [logging.md](rules/service/logging.md) | `LOG` | wide events: every failure and every interaction, on every layer |
| [metrics.md](rules/service/metrics.md) | `MET` | Prometheus: internal `/metrics`, own registry, request rate/errors/duration, label cardinality |
| [observability.md](rules/service/observability.md) | `OBS` | tracing, version reporting, profiling endpoints |
| [data-integrity.md](rules/service/data-integrity.md) | `INT` | audit log, soft delete, seeding, external state |
| [jobs.md](rules/service/jobs.md) | `JOB` | Postgres-backed work queues |
| [deployment.md](rules/service/deployment.md) | `DEP` | Docker build, single binary, runtime image |

## Standard stack (service profile)

| Layer | Choice |
|-------|--------|
| HTTP | Gin |
| Data access | sqlc (pgx/v5) + goose SQL migrations, linted by squawk and `sqlc vet` |
| Database | PostgreSQL only; embedded-postgres for dev and tests |
| Layers | controller -> service -> repository / client, every component built with an options struct in `main` |
| Config | `govengers/config` v2 (env vars, bound into one `Configuration` struct in `main`) |
| Auth | `govengers/basicauth` + `govengers/oidc-auth`, being merged into `govengers/auth` |
| Logging | `govengers/wide-event-logger` (wide events); zerolog only for startup and shutdown lines |
| Caching | `govengers/cache` |
| Real-time | WebSocket (gorilla) |
| Metrics | Prometheus (`client_golang`), own registry, `/metrics` on an internal port |
| Tracing | OpenTelemetry |
| Tasks | justfile |
| Deploy | multi-stage Docker, single binary with embedded frontend, distroless runtime |
