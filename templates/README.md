# Templates

Starting points for a new govengers repo. Copy the folder of the profile, replace `example` with the repo's name, delete what does not apply (the UI stage and the frontend recipes for a service without frontend, `openapi-check`, `pkg/` and the client generation for a service that ships no API clients). Every template follows the rules; the rule IDs in their comments say which. A new application that shares a foundation with an existing one is derived from that application instead ([playbooks/deriving-an-application.md](../playbooks/deriving-an-application.md)).

| File | Service | Library | Implements |
|------|:-------:|:-------:|------------|
| `justfile` | x | x | TCH-005 recipes, TST-014 cached `test` and uncached `test-all`, TST-015 `test-e2e` that skips an unchanged artifact, TST-010 coverage gate, TST-017 per-test budget (`test-budget`); service: TST-016 one PostgreSQL per run through the `postgrestest` launcher, `generate-check` (TCH-003), `db-check` (DAT-016), `openapi-check`, `dev` and `test-typescript` for the frontend (DEP-001) |
| `.github/workflows/ci.yml` | x | x | calls the reusable workflow in [govengers/.github](https://github.com/govengers/.github): `go-service.yml` (parallel jobs, the extra recipes, the pipeline budget of TST-018, then the image) or `go-library.yml` (checks, badges); nightly full run |
| `.github/dependabot.yml` | x | x | weekly bumps of modules, actions and digest-pinned images |
| `docker/server.Dockerfile` | x | | DEP-001..006: multi-stage, cross-compiled, digest-pinned, distroless, non-root; copies `pkg/` for a service that ships clients (LAY-001) |
| `.dockerignore` | x | | a small build context |
| `.govengers.yml` | x | x | the profile (README "Profiles") |
| `.gitignore` | x | x | `sandbox/` and test binaries |

`.golangci.yml` is the one in the repo root of the standards; a library enables the LIB-005 checks in it.

## How the test scoping works

- `just test` runs `go test` without `-count=1`. Go caches every passing package keyed on its compiled test binary and reruns a package only when something linked into it changed: the tests of the changed code and of everything that depends on it, nothing else (TST-014). Coverage is replayed from the cache, so the coverage gate still sees every package. This is sound because unit tests are hermetic (TST-013).
- The service's `just test` and `just test-e2e-all` run under the `postgrestest` launcher: one PostgreSQL for the whole run, at an address that is the same in every run of a checkout, and every test gets its own copy of the migrated template (TST-016, TST-019).
- `just test` and `just test-e2e-all` of both templates fail when a test took longer than `test_budget` (TST-017); the JSON of `go test` also carries the times of packages replayed from the cache, so a failing budget drops the test cache and the next run measures again.
- `just test-e2e` builds the server and the suite reproducibly (`-trimpath -buildvcs=false`, fixed version) and hashes them with the suite's other inputs. A green run records the hash in `sandbox/e2e-passed`; the same hash skips the suite (TST-015).
- CI restores the Go build cache and the e2e records from earlier runs: pull requests from the newest main run, main from itself. Main saves the build cache, every run saves its e2e records.
- `just test-all` and `just test-e2e-all` never skip and shuffle (TST-005). CI runs them nightly and on every `v*` tag, so a release is never tested from the cache.
- CI fails a service's pull request pipeline that took longer than 300 s with warm caches or 480 s cold, plus 20 % (TST-018).

## Checked by CI

[.github/workflows/templates.yml](../.github/workflows/templates.yml) lints the workflows with actionlint, the Dockerfile with hadolint, parses the justfiles with just and runs their `test-budget` on fixed test JSON (`.github/testdata`), so a template cannot quietly break.
