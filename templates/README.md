# Templates

Starting points for a new govengers repo. Copy the folder of the profile, replace `example` with the repo's name, delete what does not apply (the UI stage and the frontend recipes for a service without frontend, `openapi-check`, `pkg/` and the client generation for a service that ships no API clients). Every template follows the rules; the rule IDs in their comments say which. A new application that shares a foundation with an existing one is derived from that application instead ([playbooks/deriving-an-application.md](../playbooks/deriving-an-application.md)).

| File | Service | Library | Implements |
|------|:-------:|:-------:|------------|
| `justfile` | x | x | TCH-005 recipes, TST-014 cached `test` and uncached `test-all`, TST-015 `test-e2e` that skips an unchanged artifact, TST-010 coverage gate, TST-017 per-test budget (`test-budget`); service: TST-016 one PostgreSQL per run through the `postgrestest` launcher, `generate-check` (TCH-003), `db-check` (DAT-016), `openapi-check`, `vulncheck` that skips while dependencies and Go are unchanged (TCH-008), `dev`, `ui-build` and `test-typescript` for the frontend (DEP-001), TST-020 `browser-select` and `ui-e2e` (the browser journeys a change needs, skipped on a green record) with `ui-e2e-all` |
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
- `just ui-e2e` runs the browser journeys the change needs: `just browser-select` reads the changed paths (in CI against `BASE_SHA`, every journey without it; locally against the merge base with `origin/main`, untracked files included) and the `// covers:` line of every spec, and answers `all` or a `--grep` pattern of `@smoke` and the selected specs (TST-020). A green run records its key (the binaries the journeys execute, every file outside `browser_unaffected` and every claimed path with content, executable bit and a symlink's target, Bun, the selection and the shard) in `sandbox/ui-e2e-passed`; the same key skips, and an input it cannot hash fails the run.
- `just vulncheck` records a green scan of `go.mod`, `go.sum` and the Go release in `sandbox/vulncheck-passed` and skips while they are unchanged (TCH-008).
- `FULL=true` (the nightly run, `just ui-e2e-all`) ignores every record: every journey, a fresh scan.
- CI restores the Go build cache and the e2e records from earlier runs: pull requests from the newest main run, main from itself. Main saves the build cache, every run saves its e2e records.
- `just test-all` and `just test-e2e-all` never skip and shuffle (TST-005). CI runs them nightly and on every `v*` tag, so a release is never tested from the cache.
- CI fails a service's pull request pipeline that took longer than 300 s with warm caches or 480 s cold, plus 20 % (TST-018).

## What `ui-e2e` expects of the frontend

The template ships no frontend, as for `test-typescript`: the first service is the worked example and runs this recipe text. The harness contract:

- `@playwright/test` pinned in `ui/package.json`.
- `ui/playwright.config.ts` with `testDir: 'e2e'` and a `globalSetup` that starts the binary in `E2E_SERVER` on a scratch database of the launcher's PostgreSQL (`POSTGRESTEST_URL`) and exports the base URL. A further Go program it runs goes into `browser_binaries`, and the recipe passes its path in `sandbox/ui-e2e/` as it passes `E2E_SERVER`, so what the key hashes is what runs.
- Specs in `ui/e2e/*.spec.ts`, each with a `// covers:` line naming the pages its journeys open, the smoke journeys tagged `@smoke`.
- Every journey on its own state; no serial block and no worker limit in the configuration (TST-020). The recipe sets workers, full parallelism and the global timeout.
- What a run writes (`node_modules`, the build output, `playwright-report`, `test-results`) is ignored by git, or it changes the next run's key.
- The frontend the journeys run carries no per-commit stamp (a version, a commit or a build time in the bundle), or `ui-e2e` builds it with a fixed one: the server embeds the bundle, so a stamp makes every commit a new key and the journeys never skip. The template's `ui-build` stamps nothing. A service whose bundle shows its version gives `ui-build` a parameter (`ui-build stamp=version`) and lets `ui-e2e` depend on `(ui-build "e2e")`.
- Locally the recipe installs no browser (it does when `CI` is set). Once per machine and Playwright version: `cd ui && bunx playwright install --only-shell chromium`.

## Checked by CI

[.github/workflows/templates.yml](../.github/workflows/templates.yml) lints the workflows with actionlint, the Dockerfile with hadolint, parses the justfiles with just and runs their `test-budget` on fixed test JSON (`.github/testdata`), and runs the service justfile's `browser-select` on a miniature repository (`.github/testdata/journeys`), by its paths and from a small git history, and its `ui-e2e` record on a stub service with shims for Bun and Playwright, so a template cannot quietly break.
