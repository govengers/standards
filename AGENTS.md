# Agent instructions

This repo is the govengers Go standards: principles in `MANIFESTO.md`, graded rules in `rules/`, playbooks in `playbooks/`. It is the source of truth for every Go repo in the org.

## Writing Go in a govengers repo

1. Determine the profile exactly as `REVIEW.md` step 2 does: `.govengers.yml` in the repo root, otherwise a repo with a `cmd/` entry point that serves traffic or runs as a process is `service`, everything else `library`.
2. Always load these, they apply to every line you write:
   - `rules/core/naming.md`, `rules/core/functions.md`, `rules/core/design.md`, `rules/core/errors.md`
   - service: `rules/service/architecture.md`; library: `rules/library/library.md`
3. Then load the files for what the task touches. `rules/service/` files apply to the service profile only; a library applies `rules/core/` and `rules/library/`:

| Task | Read |
|------|------|
| new business object, endpoint or business action | `playbooks/business-object-lifecycle.md`, `rules/service/api.md`, `rules/service/auth.md`, `rules/service/logging.md`, `rules/service/metrics.md`, `rules/service/realtime.md`, `rules/service/data-integrity.md` |
| query, migration, transaction | `rules/service/data-access.md`, `rules/service/data-integrity.md` |
| configuration value | `rules/service/configuration.md` |
| goroutine, worker, background job | `rules/core/concurrency.md`, `rules/service/jobs.md` |
| call to another system | `rules/core/resilience.md`, ARC-005 |
| logging, error recording | `rules/service/logging.md` |
| metrics | `rules/service/metrics.md` |
| tracing, version reporting, profiling | `rules/service/observability.md` |
| WebSocket, broadcasts | `rules/service/realtime.md` |
| tests | `rules/core/testing.md` |
| startup, shutdown, Dockerfile, CI | `rules/service/layout.md`, `rules/service/deployment.md`, `rules/core/toolchain.md` |

The non-negotiables, in one line each:

- Spell every name out; only receivers, type parameters, `ctx`, `err`, test handles and the listed initialisms are short (NAM-001).
- A function does one thing, at one level of abstraction, with no side effect its name does not announce (FUN-001, FUN-002, FUN-003).
- Every component is built with `New...(options *...Options)`; only `main` reads configuration and wires components (DES-001, CFG-006, ARC-006).
- Services are cut into controller -> service -> repository / client; no layer is skipped (ARC-001, ARC-002).
- Errors are returned with context and handled once (ERR-003, ERR-004).
- New behavior ships with tests at the layer where its bugs live, and the end-to-end suite stays green (TST-001, TST-011, TST-012).

Done means the repo's `just check` (lint with `.golangci.yml`, vet, race tests, end-to-end suite) is green, and a self-review with `REVIEW.md` finds no `must` violation in the change.

## Working on this repo

- **Reviewing a Go repo against the standards:** follow `REVIEW.md`.
- **Adding or changing a rule:** follow `CONTRIBUTING.md`. Keep the rule format exact; the reviewer parses heading, severity, principle and check.
- Never renumber or reuse a rule ID. Deprecate instead.
- Playbooks must not contradict the rules. When you change a rule, update the playbooks and examples that show the old pattern.
- Examples target Go 1.26 and the standard stack in `README.md`, and follow every rule (agents copy them).
