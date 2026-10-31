# Templates

Starting points for a new govengers repo. Copy the folder of the profile, replace `example` with the repo's name, delete what does not apply (the UI stage for a service without frontend). Every template follows the rules; the rule IDs in their comments say which.

| File | Service | Library | Implements |
|------|:-------:|:-------:|------------|
| `justfile` | x | x | TCH-005 recipes, TST-014 cached `test` and uncached `test-all`, TST-015 `test-e2e` that skips an unchanged artifact, TST-010 coverage gate, DAT-016 (service) |
| `.github/workflows/ci.yml` | x | x | calls the reusable workflow in [govengers/.github](https://github.com/govengers/.github): `go-service.yml` (checks, then image) or `go-library.yml` (checks, badges); nightly full run |
| `.github/dependabot.yml` | x | x | weekly bumps of modules, actions and digest-pinned images |
| `docker/server.Dockerfile` | x | | DEP-001..006: multi-stage, cross-compiled, digest-pinned, distroless, non-root |
| `.dockerignore` | x | | a small build context |
| `.govengers.yml` | x | x | the profile (README "Profiles") |
| `.gitignore` | x | x | `sandbox/` and test binaries |

`.golangci.yml` is the one in the repo root of the standards; a library enables the LIB-005 checks in it.

## How the test scoping works

- `just test` runs `go test` without `-count=1`. Go caches every passing package keyed on its compiled test binary and reruns a package only when something linked into it changed: the tests of the changed code and of everything that depends on it, nothing else (TST-014). Coverage is replayed from the cache, so the coverage gate still sees every package. This is sound because unit tests are hermetic (TST-013).
- `just test-e2e` builds the server and the suite reproducibly (`-trimpath -buildvcs=false`, fixed version) and hashes them with the suite's other inputs. A green run records the hash in `sandbox/e2e-passed`; the same hash skips the suite (TST-015).
- CI restores the Go build cache and the e2e records from earlier runs: pull requests from the newest main run, main from itself. Main saves the build cache, every run saves its e2e records.
- `just test-all` and `just test-e2e-all` never skip. CI runs them nightly; run them locally before a release.

## Checked by CI

[.github/workflows/templates.yml](../.github/workflows/templates.yml) lints the workflows with actionlint, the Dockerfile with hadolint and parses the justfiles with just, so a template cannot quietly break.
