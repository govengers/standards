# Playbook: derive an application from a template application

Guidance, not graded. How a service that other applications start from (a template application) keeps its foundation and its own domain apart, so that `just derive` turns it into a new application with the foundation and an empty domain. The example template application is a task tracker named `tracker`; the derived one is `inventory`.

A derived application is a copy, and copies get no fixes. So the template application holds as little as possible: everything with a stable contract (login, sessions, API keys, the declared API and its clients, jobs, events, storage, mail, documents, the frontend's components) comes from the govengers libraries and govengers/ui, and the template only wires them and holds its domain. A fix the derived applications need lands in a library and reaches them with a version bump. What stays in the template (the wiring, the layout, the CI) is what an application is expected to change.

```
1. Manifest -> 2. Composition points -> 3. Derive command -> 4. CI gate -> 5. The new domain
```

## 1. A manifest names the domain

`derive/domain.txt` lists every path of the template's domain, one per line, `#` for comments:

```
# Every path of the domain, the task tracker. `just derive` removes them; the files that are
# also in derive/_skeleton are composition points and come back as stubs.
# The foundation never imports or names anything listed here.
cmd/server/domain.go
cmd/server/domain_test.go
internal/controller/domain.go
internal/controller/task.go
internal/database/domain.go
internal/database/migrations/00100_tasks.sql
internal/generated/domain.go
internal/model/task.go
internal/repository/queries/tasks.sql
internal/repository/task.go
internal/service/task.go
ui/src/domain.ts
ui/src/pages/Tasks/
ui/test/domain.ts
test/e2e/task_test.go
```

Everything not listed is the foundation. The rule that keeps the split honest: the foundation never imports or names a domain path. The CI gate (step 4) enforces it, because a foundation that does is a derived application that does not build.

Number the domain's migrations apart from the foundation's (foundation `00001` to `00099`, domain from `00100`), so the foundation can add a migration later without colliding with any derived application's.

## 2. Composition points: where the foundation asks for the domain

The foundation reaches the domain only through a few files with a fixed shape, one per layer that has to know the domain. Each exists twice: the template's own in the tree, and an empty stub in `derive/_skeleton/` that the derive command puts in its place.

| Layer | File | Holds |
|-------|------|-------|
| wiring | `cmd/server/domain.go` | `newDomain(...)`: builds the domain's repositories and services from what `main` hands it (the pool, the foundation's repositories), ARC-006 |
| controller | `internal/controller/domain.go` | `DomainServices`, the struct of the domain's services, and `domainDeclarations(...)`, the domain's API declarations |
| database | `internal/database/domain.go` | the domain's Go migrations (triggers, history tables), numbered from 101 |
| generated clients | `internal/generated/domain.go` | the API's description and the domain's enums for the generated clients |
| contract tests | `cmd/server/domain_test.go` | the domain's reads and writes for the foundation's contract tests (authorization, audit, change feed on every endpoint) |
| frontend | `ui/src/domain.ts` | the domain's routes, navigation entries, API key scopes and where `/` lands |
| frontend tests | `ui/test/domain.ts` | the domain's rows and calls for the fake API the component tests run against |

```go
// derive/_skeleton/cmd/server/domain.go: what a derived application starts from
// newDomain wires the domain's repositories and services (ARC-006): main's composition point
// of the domain.
func newDomain(_ *pgxpool.Pool, _ *repository.UserRepository) (controller.DomainServices, error) {
    return controller.DomainServices{}, nil
}
```

`main` calls `newDomain` in its service layer step and passes the result to the controller step (LAY-002); `domain.go` is the one file besides `main.go` in `cmd/server/` (LAY-001). Keep the number of composition points small and their signatures stable: every one is a place where a derived application and the template drift apart. A domain need the stub cannot express is a sign the foundation should offer it (an option, a hook), not that the derived application should edit the foundation.

Lines of a shared file that belong to the domain (a product line in the design doc, an exception for a domain page) end in a marker comment such as `<!-- domain -->`; the derive command drops them.

## 3. A derive command

`just derive <name> <module> <target>` runs `hack/derive.sh`:

1. Validate the name: it becomes the API key prefix, the metrics namespace, the CLI's name and its environment prefix, so it is lower-case letters and digits starting with a letter (govengers/auth's key prefix rule). Refuse a target that exists and is not empty.
2. Copy the working tree as git sees it (`git ls-files --cached --others --exclude-standard`): committed and new files, nothing ignored, no `sandbox/`, no `node_modules`.
3. Remove every path of the manifest, copy the stubs of `derive/_skeleton` in, delete `derive/_skeleton` and leave an empty manifest for the new application, so it can be a template itself.
4. Rename the module path first, then every spelling of the template's name (`tracker`, `TRACKER`, `tracker_`), and move `cmd/<old>` to `cmd/<name>`.
5. Regenerate: `go tool sqlc generate`, the API clients (`go run ./cmd/generate`: `pkg/apiclient`, `pkg/command`, `ui/src/api`, `openapi.yaml`), `go mod tidy`.

```sh
just derive inventory github.com/example/inventory ../inventory
cd ../inventory && just check
```

The derived repository is a new repository with its own history; it does not keep a remote to the template. Its README says which template version it was derived from.

## 4. A CI gate derives and builds the sample application

`just derive-check` derives a sample application into a stable directory (`sandbox/derive-check`, so its test server and Go test cache are reused between runs) and runs the derived application's gates there: build, vet, lint, unit tests, the frontend's checks and build. CI runs it as an extra recipe of the reusable service workflow (`recipes: '["derive-check", ...]'`). The workflow calls a recipe without arguments and exports `FULL=true` on the nightly and tag runs, so the recipe adds `-count=1 -shuffle=on` itself then (TST-014) and ignores its record. The record keeps the derivation out of the hot path (TST-018): a change derives when the derivation's own inputs or the justfile changed, the nightly always.

```just
derive_inputs := "hack/derive.sh derive"

derive-check *flags:
    #!/usr/bin/env bash
    set -euo pipefail
    key=$(find {{derive_inputs}} justfile -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 -- | shasum -a 256 | cut -c1-32)
    passed="$PWD/sandbox/derive-passed/$key"
    if [ -z "{{flags}}" ] && [ "${FULL:-false}" != true ] && [ -f "$passed" ]; then
        echo "derive-check skipped: the derivation's inputs equal the green run $key"
        exit 0
    fi
    rm -rf sandbox/derive-check
    hack/derive.sh sample github.com/example/sample sandbox/derive-check
    cd sandbox/derive-check
    "{{just_executable()}}" test-typescript
    go build ./...
    go vet ./...
    golangci-lint run ./...
    full=""
    if [ "${FULL:-false}" = true ]; then full="-count=1 -shuffle=on"; fi # the reusable workflow's full run
    go tool postgrestest go test $full {{flags}} ./... # the template's own test job runs them with the race detector
    if [ -z "{{flags}}" ]; then mkdir -p "${passed%/*}" && touch "$passed"; fi
```

The gate is what makes the manifest true: a foundation file that starts to import a domain package, a migration of the foundation that references a domain table, a frontend page of the foundation that links a domain route all fail it, in the pull request when it changes the derivation, otherwise in the night's full run, whose red run opens an issue (TST-021). Reference: the first template application measured 13 s for `just derive-check` locally, and the job ran in parallel with the unit tests in CI.

## 5. Adding the new domain

The derived application has the foundation and an empty domain. Add the domain one business object at a time ([business-object-lifecycle.md](business-object-lifecycle.md)):

| Step | Where |
|------|-------|
| tables | `internal/database/migrations/00100_<domain>.sql`; triggers and history in `internal/database/domain.go` (from 101) |
| queries | `internal/repository/queries/<object>.sql`, then `just generate` |
| model, repository, service | `internal/model/<object>.go`, `internal/repository/<object>.go`, `internal/service/<object>.go` |
| declarations | `internal/controller/<object>.go`, the services in `DomainServices` |
| wiring | `cmd/server/domain.go` |
| payloads, enums | `pkg/api/<object>.go`, `internal/generated/domain.go`, then `just generate` |
| tests | the domain's reads and writes in `cmd/server/domain_test.go`, the end-to-end journey in `test/e2e/<object>_test.go`, the browser journeys of the core object in `ui/e2e/<object>.spec.ts`, one of them `@smoke`, with a `// covers:` line claiming the object's pages (TST-020) |
| frontend | pages under `ui/src/pages/<Domain>/`, routes and navigation in `ui/src/domain.ts`, fake rows in `ui/test/domain.ts` |

List every new domain file in `derive/domain.txt` if the application is to be a template itself, and keep its own `derive-check` in CI.

## What goes wrong

- **A fix in the template's foundation.** It reaches no derived application. Put it into the library it belongs to, or, when it is wiring, describe it in the template's changelog so derived applications can port it by hand.
- **A generic capability built in the template** (a cache, a mail sender, an upload handler). Every derived application then owns a copy. Build it in a library with a conformance suite and wire it from the template.
- **A foundation test that seeds domain rows.** It breaks in every derived application. Seed through the contract-test composition point (`cmd/server/domain_test.go`) instead.
- **A rename that misses a spelling.** The derive command renames by pattern; a name spelled another way (`Tracker` in a page title, a database object prefix) survives into the derived application. Keep one spelling per context and let `derive-check` grep the derived tree for the old name.
