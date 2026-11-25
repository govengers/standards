# Testing (`TST`)

Profile: core

### TST-001 New behavior ships with a test

- **Severity:** must
- **Principle:** P9
- **Check:** a change that adds or changes behavior (a branch, a query, an endpoint, a permission rule, a parser) without a test that fails when that behavior breaks.

Trivial wiring and one-line delegations need no dedicated test. Bug fixes come with a regression test that reproduces the bug.

### TST-002 Test against a real database, not a mock

- **Severity:** must
- **Principle:** P5, P9
- **Check:** repository or query tests that mock the database driver or the sqlc `Queries`; service tests that replace a repository with a mock or fake; tests that run against SQLite while production runs Postgres.

Mocks hide broken migrations, constraint violations and SQL errors - the bugs that matter at this layer. Use a real PostgreSQL through `github.com/govengers/postgrestest` (TST-016): every test gets its own database, a copy of a template that the app's own migrator built once.

```go
func TestCreateUserRejectsDuplicateUsername(t *testing.T) {
    userRepository, err := repository.NewUserRepository(&repository.UserRepositoryOptions{Pool: testdatabase.New(t)})
    require.NoError(t, err)

    _, err = userRepository.Create(t.Context(), parameters)
    require.NoError(t, err)

    _, err = userRepository.Create(t.Context(), parameters)
    require.ErrorIs(t, err, model.ErrConflict)
}
```

A database shared by several tests fails on the second run because of leftover rows. A server shared by every test is fine (TST-013): the database is what each test owns.

### TST-003 Every permission checker has allowed and denied tests

- **Severity:** must
- **Principle:** P9
- **Check:** an authorization checker or broadcast filter without a test for at least one allowed and one denied case.

Authorization bugs are silent: nothing fails, the wrong person just sees the data.

```go
func TestIsAdmin(t *testing.T) {
    as := func(identity *auth.Identity) context.Context { return auth.WithIdentity(t.Context(), identity) }
    require.NoError(t, authorization.IsAdmin()(as(&auth.Identity{Roles: []string{auth.RoleAdmin}, Active: true})))
    require.ErrorIs(t, authorization.IsAdmin()(as(&auth.Identity{Active: true})), auth.ErrForbidden)
    require.ErrorIs(t, authorization.IsAdmin()(as(&auth.Identity{Roles: []string{auth.RoleAdmin}, Active: false})), auth.ErrForbidden)
}
```

### TST-004 Tests pass with the race detector

- **Severity:** must
- **Principle:** P8, P9
- **Check:** CI runs `go test` without `-race`, or tests that are skipped under `-race`.

### TST-005 Tests do not depend on wall-clock time or each other

- **Severity:** should
- **Principle:** P9
- **Check:** `time.Sleep` to wait for async work; assertions on `time.Now()`; real timers of seconds in tests; retries that wait a real backoff; tests that only pass in a given order or fail under `-count=2`.

Inject a clock, a short interval or the backoff through the options struct; wait on a channel or poll with a deadline instead of sleeping. A sleep is the most common reason a test goes over its time budget (TST-017).

```go
// bad
time.Sleep(2 * time.Second)
require.Equal(t, 1, sent)

// good
require.Eventually(t, func() bool { return sent.Load() == 1 }, time.Second, 10*time.Millisecond)
```

### TST-006 Use stdlib test servers for HTTP

- **Severity:** should
- **Principle:** P2, P9
- **Check:** HTTP clients tested against mocked transports or interfaces where `httptest.NewServer` would exercise the real client; handlers tested by calling internals instead of `httptest.NewRecorder`.

```go
testServer := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
    if attempts.Add(1) <= 2 {
        writer.WriteHeader(http.StatusBadGateway)
        return
    }
    writer.WriteHeader(http.StatusOK)
}))
defer testServer.Close()
```

### TST-007 Table tests for input-output logic

- **Severity:** should
- **Principle:** P1, P9
- **Check:** copy-pasted test functions that differ only in input and expected output.

Use a table with named cases and `t.Run(testCase.name, ...)`, so a failure names the case. Example: FUN-005.

### TST-008 Assert with testify `require`, one library per repo

- **Severity:** should
- **Principle:** P2
- **Check:** a mix of assertion libraries in one repo; `assert` where the test cannot continue meaningfully after the failure.

`require` stops at the first failed precondition, which avoids nil-pointer noise in the rest of the test.

### TST-009 Fail tests on leaked goroutines

- **Severity:** should
- **Principle:** P6, P9
- **Check:** a package that starts goroutines (workers, pollers, broadcasters, clients with background loops) without `goleak.VerifyTestMain` or `goleak.VerifyNone`.

A leaked goroutine is a slow memory leak with no error and no log line; in production it shows up as an OOM kill weeks later. `goleak` turns it into a test failure (CON-006).

```go
func TestMain(m *testing.M) {
    goleak.VerifyTestMain(m)
}
```

### TST-010 Keep unit test coverage high and gate it in CI

- **Severity:** should
- **Principle:** P8, P9
- **Check:** CI that does not fail on low coverage; coverage of new code below 80% in `service`, `repository`, `client` and library packages; tests that execute code without asserting on its result.

Coverage does not prove a test is good, but uncovered code is untested for certain. The gate for new code is Sonar's "Coverage on New Code" (80%), fed with the `-coverprofile` of the unit tests. A repo without Sonar gates total coverage instead, which is weaker but never silent. Generated code and `cmd/` are excluded; `main` is covered by the end-to-end suite (TST-011).

```just
test:
    go test -race -coverprofile=sandbox/unit.cover ./...
    grep -v -e '/cmd/' -e '/internal/sqlc/' sandbox/unit.cover > sandbox/unit.filtered.cover
    go tool cover -func=sandbox/unit.filtered.cover > sandbox/unit.func
    awk '/^total:/ { found = 1; sub("%", "", $3); if ($3 + 0 < 80) { print "coverage " $3 "% is below 80%"; exit 1 } } END { if (!found) { print "no coverage total"; exit 1 } }' sandbox/unit.func
```

Each recipe line fails on its own, so a failing `go tool cover` stops the recipe instead of disappearing in a pipe.

### TST-011 Every repo has an end-to-end suite, green before merge

- **Severity:** must
- **Principle:** P9, P10
- **Check:** no end-to-end suite; a suite that CI does not run or whose failure does not block the merge; end-to-end tests skipped or quarantined without a linked issue; end-to-end tests without the `e2e` build tag, so plain `go test ./...` runs them without their setup.

Unit tests prove the parts; the end-to-end suite proves the artifact. For a service it builds the real binary, starts it on a free port with an explicit test environment against a fresh Postgres, with external systems replaced by `httptest` servers, and drives the public API through the main flows of every business object (create, read, list, update, delete, the permission denials). A service with a UI adds browser tests (Playwright) for the main user journeys. For a library, the suite exercises the public API with real collaborators: a real HTTP server, a real identity provider or a fake issuer that speaks the protocol.

The suite lives in `test/e2e/`, every file starts with `//go:build e2e`, and `.golangci.yml` sets `run.build-tags: [e2e]` so lint still sees it. The harness starts the binary from the absolute path in `E2E_BINARY` with `GOCOVERDIR` passed through, waits for `/api/health`, and stops it with SIGTERM and waits for the exit: a binary built with `-cover` writes its coverage data only when it exits normally.

```just
# e2e-build is in TST-015: a reproducible build, so an unchanged binary can skip the suite
test-e2e-all: e2e-build
    rm -rf sandbox/coverage && mkdir -p sandbox/coverage
    E2E_BINARY={{justfile_directory()}}/sandbox/e2e-build/server GOCOVERDIR={{justfile_directory()}}/sandbox/coverage go test -tags e2e -trimpath -buildvcs=false -count=1 ./test/e2e/...
    go tool covdata percent -i=sandbox/coverage
```

The suite runs uncached (`-count=1`): it depends on a running binary, which the test cache cannot see. TST-015 decides when it may be skipped.

### TST-012 Test each layer where its bugs live

- **Severity:** should
- **Principle:** P9
- **Check:** a layer tested with the wrong kind of double: a repository mocked in service tests, a client tested against a mocked transport, a controller tested by calling the service directly instead of going through the router, a business rule tested only through HTTP.

| Under test | Test with |
|------------|-----------|
| pure business rules (FUN-005) | table tests, no I/O |
| repository | a real Postgres per test (TST-002) |
| client | `httptest.NewServer` (TST-006) |
| service | real repositories on a per-test Postgres; fakes only for clients and broadcasters, through the interfaces the service declares (ARC-005) |
| controller | `httptest.NewRecorder` through the real router and the real service: status codes, payload validation, permission denials |
| the whole application | the end-to-end suite (TST-011) |

### TST-013 Tests outside the end-to-end suite are hermetic

- **Severity:** must
- **Principle:** P8, P9
- **Check:** a test without the `e2e` build tag that connects to anything other than a server it started itself or the test run started for it (an `httptest` server, the embedded PostgreSQL of govengers/postgrestest); that uses a database it did not create for itself; that depends on a service it did not start (a shared database from `DATABASE_URL`, Docker Compose, a staging API); that reads files outside its module other than `t.TempDir()`; or that relies on state another test or an earlier run left behind.

`go test` caches a passing package and replays the result until the compiled test binary, an environment variable it read or a module file it opened changes (TST-014). Everything else is invisible to the cache: a test against a shared database stays green in the cache after the database changed. Hermetic tests are also the only ones that give the same result on every laptop and every runner. Whatever needs a running system belongs in the end-to-end suite.

One PostgreSQL server for every test of a run is hermetic, as long as every test owns its database, a fresh copy of the migrated template (TST-016), and the server's address is the same in every run (TST-019). The server is infrastructure like the Go toolchain; the database is the test's state.

```go
// bad: a database the test does not own and the cache cannot see
pool, err := pgxpool.New(t.Context(), os.Getenv("DATABASE_URL"))

// good: a fresh copy of the migrated template, for this test alone (TST-016)
pool := testdatabase.New(t)
```

### TST-014 Let the test cache skip unchanged packages

- **Severity:** should
- **Principle:** P8
- **Check:** `-count=1` or another flag that disables caching in the default `just test` recipe or the CI unit test step; CI that does not carry the Go build cache from one run to the next; no scheduled full run (`just test-all`, `just test-e2e-all`, every browser journey); a full run that does not shuffle; a scheduled run nobody is told about (TST-021).

`go test` already runs only what changed. It caches each passing package keyed on its compiled test binary and reruns it only when something linked into that binary changes: a change in `internal/service/billing` reruns the tests of billing and of every package that links it, nothing else. That is more precise than selecting packages from a git diff: the key sees through dead code and includes embedded files, `go.mod` and the environment variables the tests read. `-race`, `-coverprofile`, `-json`, `-run`, `-short` and `-v` keep the cache on, and coverage is replayed from it, so the coverage gate (TST-010) still sees every package. `-count=1` turns it off and runs everything, every time.

The cache is only sound for hermetic tests (TST-013) whose inputs stay the same from run to run (TST-019). A flaky test that passed once stays cached until its package changes, so a full run runs nightly on main, on every `v*` tag and on demand (`workflow_dispatch`, which confirms a fix without waiting a night): `just test-all` and `just test-e2e-all`, uncached and `-shuffle=on` (TST-005), every browser journey (TST-020) and the vulnerability scan (TCH-008), none of them skipped by a record (TST-015). A red full run opens an issue with an assignee (TST-021): what the hot path leaves out (TST-018) is checked nowhere else. In CI the govengers reusable workflow restores each job's build and test cache from the newest main run; pushes to main save it, and so does a pull request that found no cache of its Go release and `go.sum`.

```just
# Changed and affected packages; the test cache replays the rest
test *flags:
    mkdir -p sandbox
    go test -race -coverprofile=sandbox/unit.cover {{flags}} ./...

# Every package, uncached and shuffled: nightly and before a release
test-all: (test "-count=1" "-shuffle=on")
```

### TST-015 Skip the end-to-end suite only when what it runs is unchanged

- **Severity:** should
- **Principle:** P8, P9
- **Check:** CI that runs the end-to-end suite or the browser journeys although neither the binary, the suite nor their inputs changed; a skip decided by changed paths or a git diff instead of the built artifacts; a skip key without the suite's non-Go inputs (compose files, fixtures, Playwright specs, the frontend's tracked files, the Bun version); a scheduled or release run that honors the skip.

The suite tests the whole artifact, so it cannot be scoped by package. The artifact itself says whether anything changed: built with `-trimpath -buildvcs=false` and a fixed version, the binary and the compiled suite are byte-identical for identical code, differ for every change that reaches them, and stay identical when only code they do not link changes (another `cmd`, a tool, docs). Their hash plus the suite's other inputs is the key; a green run records it, and a run whose key is recorded skips. Path filters are the wrong tool: they cannot tell whether a changed file reaches the binary, so they run the suite for changes it never sees or miss inputs nobody listed.

```just
e2e_inputs := "test/e2e"

# Reproducible server and suite binaries: their hash says whether the suite has anything new to test
e2e-build:
    mkdir -p sandbox/e2e-build
    go build -cover -trimpath -buildvcs=false -ldflags "-X main.version=e2e" -o sandbox/e2e-build/server ./cmd/server
    go test -c -tags e2e -trimpath -buildvcs=false -o sandbox/e2e-build/ ./test/e2e/...

# The suite, skipped when binary, suite and inputs equal a green run
test-e2e: e2e-build
    #!/usr/bin/env bash
    set -euo pipefail
    key=$(find sandbox/e2e-build {{e2e_inputs}} -type f -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | cut -c1-32)
    if [ -e "sandbox/e2e-passed/$key" ]; then echo "e2e skipped: equal to the green run $key"; exit 0; fi
    "{{just_executable()}}" test-e2e-all
    mkdir -p sandbox/e2e-passed && touch "sandbox/e2e-passed/$key"
```

CI carries `sandbox/e2e-passed` from run to run; the nightly run calls `just test-e2e-all`, which never skips. The browser journeys skip the same way: their key is the Go programs they execute (the server and every program the harness runs, built reproducibly after the frontend, so Go code, its dependencies and what it embeds are in the key), every file that exists and git tracks or does not ignore outside `browser_unaffected`, and every path a spec claims (path, content, executable bit and a symlink's target), the Bun version, the selection and the shard. A skip record says "nothing changed", the selection of TST-020 says "which part changed"; the journeys use both, and the record's key includes the selection, so a record satisfies exactly the selection it ran. The full recipes are in [templates/](../../templates/).

### TST-016 One PostgreSQL per test run through govengers/postgrestest, a migrated template copied per test

- **Severity:** should
- **Principle:** P2, P8
- **Check:** a repo with its own embedded-PostgreSQL harness (a copied `internal/postgrestest`, a `TestMain` that starts embedded-postgres itself) instead of `github.com/govengers/postgrestest`; a PostgreSQL server started per test; migrations applied per test instead of once into a template; a `just test` that runs several PostgreSQL packages without the launcher (`postgrestest`).

Copies of a harness get no fixes, and the slow ones cost every CI run half a minute: unpacking the binaries with a pure-Go xz under `-race` took 27 s, the system tar 5 s. postgrestest starts the server, builds the template once with the app's own migrator and gives every test `CREATE DATABASE ... TEMPLATE` (about 20 ms) instead of a migration run that grows with the schema. The launcher `postgrestest <command>` starts one server for the whole `go test ./...` and points every test binary at it through `POSTGRESTEST_URL`; a package run on its own (`go test ./internal/repository`) starts its own server. The library also tunes the server for tests, keeps the binaries in `~/.embedded-postgres-go` (CI caches that directory), bounds concurrent creates and drops, and stops servers that crashed runs left behind without touching another checkout's.

```go
// internal/testdatabase: the per-test database helper of LAY-001
var server = postgrestest.New(&postgrestest.Options{
    Migrate:     database.MigrateConnection, // the app's own goose migrations, run once
    Fingerprint: database.MigrationsFingerprint, // postgrestest.FingerprintFS(migrations): a long-lived server rebuilds the template only when it changes
})

func Main(m *testing.M) { goleak.VerifyTestMain(server.Main(m)) }

// New returns a pool on a fresh copy of the migrated template, dropped after the test.
func New(t *testing.T) *pgxpool.Pool { return server.Pool(t) }
```

```just
postgrestest := "go tool postgrestest"

test *flags:
    {{postgrestest}} {{gotestsum}} --format testname --jsonfile sandbox/unit.json -- -race {{flags}} ./...
```

Every test package calls `testdatabase.Main(m)` in its `TestMain`. The `server` variable is the one package variable a test helper may hold (DES-003), and it needs no exception in `.govengers.yml`. A service whose tests need several schemas gives each its own template with `server.WithTemplate`.

### TST-017 Report every test's time from the test JSON; a test over its budget warns, it never fails the run

- **Severity:** should
- **Principle:** P8, P9
- **Check:** `just test` or `just test-e2e-all` without a report of the test times (the ten slowest tests in the job summary, a warning annotation for each test over the budget, default 5 s with the race detector); a budget read from wall clock or log output instead of the JSON of `go test` (`gotestsum --jsonfile`); a step that fails the run because one test took longer than the budget; a slow test kept out of the report by an allowance list without a reason.

A slow test is a defect with a known set of causes: a sleep or a real backoff (TST-005), production cost parameters (Argon2 at production strength costs several seconds per test under `-race`: inject cheap parameters through the options), a server started per test (TST-016), a migration per test. The report names each of them in the pull request that adds it, instead of the day the suite has become slow. It does not fail the run: a wall-clock limit per test on shared runners is noise under load, and it blocks merges the hot path cap would let through. The only hard time rule is the cap of TST-018; when the cap breaks, the report names the test to speed up. The JSON names every test and subtest with its duration, also for packages replayed from the cache (they report the run that was cached), so the report sees the whole suite on every run. A parent test counts its sequential subtests.

```just
test_budget := "5s"

# after the tests, in the test recipe: a warning per test over the budget, never a failure
slow="$(go tool gotestsum tool slowest --jsonfile sandbox/unit.json --threshold {{test_budget}})"
if [ -n "$slow" ]; then while read -r package test elapsed; do echo "::warning title=TST-017 slow test::$package $test took $elapsed"; done <<< "$slow"; fi
```

The templates' `test-budget` also prints the ten slowest tests and writes them to the job summary. An allowance list, if a repo needs one, names the package, the test, its own budget and the reason, and stays short: each entry is a test somebody should make faster.

### TST-018 The hot path stays under ten minutes, and CI fails over it

- **Severity:** must
- **Principle:** P8
- **Check:** a pipeline that gates a deployment without a cap from the run's start to the pushed image (pull request: to the required check), or with a cap above 600 s; a cap that only prints, or that is not judged inside the check branch protection requires; a job timeout raised to make room instead of the suite made faster, split or moved to the scheduled run; a pull request pipeline that does not build the image the default branch pushes; a scheduled run that does not run what the hot path leaves out. With the govengers service workflow (`go-service.yml`): `hot-path-seconds` unset or above 600, or `budget-warm-seconds` and `budget-cold-seconds` unset. With the library workflow (`go-library.yml`): `budget-seconds` unset.

Every change waits for the pipeline, and a pipeline grows by seconds nobody notices. Where it bit: a service whose pipeline grew to almost an hour without one change that looked slow. A browser suite of some 240 journeys ran on one worker because the journeys shared state (27 minutes, the job's timeout raised from 20 to 30 to 45 minutes); an upgrade test ran serial scenarios with real 60 s waits (53 minutes); unit tests ran serially on real timers; all of it sat in front of build and deploy. The cap turns that growth into a failure in the pull request that causes it.

- **Hot path run:** a run triggered by a pull request or by a push to the default branch. Nothing else decides it: `full: true` on such an event is still capped. Scheduled runs, dispatched runs (`workflow_dispatch`) and `v*` tags are full runs, outside the cap.
- **Span:** from the run's start (`run_started_at`) to the clock of the required check, whose last step judges the cap. The check needs every job and, on the default branch, the job that tags the pushed image, so the span ends with the check result on a pull request and with the pushed image plus the verdict on the default branch. Every wait counts: for runners, for the image job's turn, for the check's own runner. A busy runner pool makes the run slower, and the verdict says so.
- **Cap:** 600 s, without margin; the workflow refuses a higher value. It is the one hard time limit: per-test times are reported, never failed (TST-017). A pull request is capped 60 s lower (540 s): the default branch also pushes the image, saves the compile cache and tags, and a pull request must predict that run. So a pull request builds the image for every platform, without pushing it.
- **Blocking:** the verdict is a step of the check branch protection requires, so a pull request over the cap cannot merge and no job can be skipped around it. Where the repository cannot require checks (a private repository on GitHub's free plan has no branch protection), the red check is advisory, and nobody merges a pull request whose check is red. On the default branch the image is out when the verdict falls; the red run is the alarm. The cap judges a run as it ran, with the skips of its green-run records, so a complete re-run or an empty commit after an attempt over the cap can pass: the cap stops a pipeline from growing unnoticed, not a deliberate bypass, and the scheduled full run bounds every job.
- **Early warning:** the warm and cold budgets, judged over the same span, fail a pull request long before the cap is near: 300 s warm and 480 s cold, failing above 20 % over. Warm means the jobs restored a cache of the same Go release and `go.sum`; cold is a new dependency or toolchain.
- **Timeouts are a backstop, not the cap:** every job that runs the caller's code gets `timeout-minutes: 10` in a hot path run and 60 in a full run, the required check 5, and no caller input changes them. They end a hung job. The 60 minutes per job keep what moved out of the hot path from growing without limit there: a job of a full run over an hour fails, and the red run opens an issue (TST-021).

| In the hot path | Recipe or job |
|-----------------|---------------|
| lint, vet | `just lint` |
| unit tests of changed and affected packages, race detector, coverage gate, a report of the slowest tests | `just test` (TST-014, TST-017) |
| API end-to-end suite unless server and suite equal a green run | `just test-e2e` (TST-015) |
| generated code, migrations and queries, OpenAPI against the base | `generate-check`, `db-check`, `openapi-check` |
| frontend type-check, component and page tests, build | `just test-typescript` |
| the browser journeys the change needs | `just ui-e2e` (TST-020) |
| image build for every platform; push by digest and tags on the default branch | the workflow's image jobs |
| govulncheck, only when `go.mod`, `go.sum` or the Go release differ from a green scan | `just vulncheck` with a record (TCH-008) |
| derivation check of a template application, only when the derivation's own inputs differ from a green run | `just derive-check` with a record ([playbook](../../playbooks/deriving-an-application.md)) |

| Out of the hot path: nightly, `v*` tags and on demand (`workflow_dispatch`) | Recipe |
|---|---|
| every unit and end-to-end test, uncached and shuffled | `just test-all`, `just test-e2e-all` |
| every browser journey | `just ui-e2e-all` (`FULL=true just ui-e2e`) |
| govulncheck regardless of the record | `FULL=true just vulncheck` |
| the derivation check regardless of the record | `FULL=true just derive-check` |

The image fits because it is built beside the checks, with the compile cache carried between runs (DEP-002), and tagged only after every check passed: a deploy follows tags, so nothing deploys an image whose checks failed. The govengers service workflow does this with `hot-path-seconds: 600`; the library workflow judges its job's own clock against `budget-seconds`. Their inputs are in the README of govengers/.github.

Reference: the first service built on the whole library set (unit, end-to-end, browser and derivation jobs in parallel, PostgreSQL 18, race detector, coverage). Rows marked pending are measured on its first runs in hot path mode.

| Run | Runner | Wall clock |
|-----|--------|-----------|
| hot path, pull request, warm caches | pending | pending |
| hot path, pull request, cold caches (nothing restored) | pending | pending |
| hot path, push to the default branch, to the pushed image | pending | pending |
| before the hot path: push to the default branch, checks then image | GitHub-hosted | 565 to 705 s |
| before the hot path: pull request, checks only, cold and warm caches | GitHub-hosted | 326 s, 68 s |
| every browser journey (23), two workers | GitHub-hosted | 56 s |
| `just test` locally, cold (template built, test cache empty) | M-series laptop | 8 s for 89 tests; slowest test 3.4 s |
| `just test` locally, nothing changed | M-series laptop | 0.9 s, every package from the cache |
| `just test-e2e` locally, without and with a green record | M-series laptop | 6.6 s, under 2 s |
| copy of the migrated template per test | M-series laptop | 20 to 40 ms |

### TST-019 Test inputs stay the same from run to run

- **Severity:** should
- **Principle:** P8
- **Check:** a test that reads an environment variable whose value changes between runs (a random port, a timestamp, a temporary path); a test that opens a file inside the module that a recipe rewrites before every run; a test server address derived from the process ID or chosen at random and passed through the environment; a launcher started differently in CI and locally (`go run` once, `go tool` the other time), which changes `PATH`.

`go test` keys a cached result on the test binary, every environment variable the binary read with its value, and every file inside the module it opened, by size and modification time (TST-014). One changing input reruns the whole package on every run, silently: nothing fails, CI just gets slower. A shared test server therefore lives at an address derived from the checkout's path (postgrestest's launcher does this), and a test that needs a scratch file writes it into `t.TempDir()`. Check it once after changing a harness: the second `just test` reports every package `(cached)`; `GODEBUG=gocachetest=1 go test ./pkg` lists the inputs.

### TST-020 Browser journeys run in parallel on their own state; a change runs the journeys it needs, the scheduled run all of them

- **Severity:** should
- **Principle:** P8, P9
- **Check:** a Playwright run with one worker, without full parallelism, or with a serial block; a journey that reads what another journey wrote, asserts on a shared person's inbox or counters, or depends on order; a pull request that runs every journey whatever changed, or smoke only although the change touches a frontend area; a selection in which a path nobody classified runs less than every journey; a selection that differs between CI and the local recipe; no `@smoke` tag; a selected run without a global timeout of at most 180 s; a suite kept inside it by a longer timeout instead of a shard; the full set not run on the scheduled run and on `v*` tags; a browser job that downloads the browser every run or uploads no report on failure.

A browser journey costs seconds, a browser and a running server, and it fails for reasons that have nothing to do with the change. Pages and components are tested in a second against a fake of the API (`bun test` with jsdom), the API by the end-to-end suite; the browser proves that the pieces fit. One worker on shared state is how a suite of some 240 journeys came to take 27 minutes (TST-018).

**Own state, in parallel.** A journey creates what it asserts on (its project, its tasks, and its own person where it asserts on a person's inbox or settings) and never reads what another journey wrote. Then any journey can run beside any other: the recipe passes `--fully-parallel`, `--workers` (at least two) and `--global-timeout`, 180 s for a selected run and 600 s for the full set, so the limits hold whatever the Playwright configuration says. A serial block in a spec or a worker limit in the configuration still wins over the flags, which is why the check names them. A suite that no longer fits gets a shard (`SHARD=1/2`, one CI job each), never a longer timeout and never fewer workers.

**Selection.** One recipe, `just ui-e2e`, locally and in CI. It asks `just browser-select` which journeys the change needs and passes the answer to `playwright test --grep`. The changed paths: in CI the diff of `BASE_SHA` (the pull request's base commit, on a push the commit before it) against the checkout, a direct comparison that also sees a push moving the branch back; locally the diff of the merge base of `HEAD` with `origin/${BASE_REF:-main}` against the working tree, plus untracked files. A rename counts with its old and its new path. A base that is not a commit of a full clone (a first push, zeros, a shallow clone), and CI without `BASE_SHA`, select every journey.

A spec names the paths whose journeys it holds in one comment line, repository relative, space separated; several specs may claim one path:

```ts
// covers: ui/src/pages/Users ui/src/pages/Account
```

A spec always covers itself, and the `@smoke` journeys (login, the main journey of the core business object) always run. Per changed path, in this order:

1. `FULL=true`: every journey.
2. The path is a spec, or lies at or below a path some spec claims: those specs, whole. Claims come first, so a claimed Markdown file (the changelog a page renders) or a claimed test file selects its spec.
3. The path lies at or below an entry of `browser_unaffected`: nothing beyond smoke. The list names what the journeys do not need beyond smoke, the backend (the API end-to-end suite covers it) and prose, and it stays explicit and short.
4. Anything else: every journey. That is the default for every path nobody classified: shared components, the generated API client, the lockfile, the Playwright configuration, the justfile, a page no spec claims, a new top-level directory.

The result is `all` or one pattern, `@smoke|accounts\.spec\.ts|tasks\.spec\.ts`, each spec once; Playwright matches `--grep` against the file name, the titles and the tags of a test, so one invocation runs the selection. A claimed path that does not exist fails the selection with the spec and the path: a typo or a moved page is fixed in the claim, not silently unmapped. Forgetting a claim is safe, an unclaimed page runs every journey. The honest limit: a change of the API contract regenerates the shared client and runs every journey. Selection saves the page-only and backend-only changes; own state and parallelism keep every journey inside the budget.

**Skip and full run.** A selected run skips like TST-015, and its key includes the selection and the shard. `browser_unaffected` is also left out of that key, so it may hold only Go code and embedded files, which the binaries fingerprint, and files no journey process reads; a path a spec claims stays in the key even below it, since its change selects the spec. The key fails the run when it cannot hash an input, instead of leaving the input out. The scheduled run and `v*` tags run every journey (`just ui-e2e-all`, `FULL=true`) and ignore the records. The CI job carries the browser's download between runs and uploads the report on failure. The recipes are in the [service justfile template](../../templates/service/justfile); what they expect of the frontend is in the [templates README](../../templates/README.md).

Reference: the first service's 23 journeys take 56 s in CI on two workers; three smoke journeys take 2.6 s locally including the frontend build.

### TST-021 A red scheduled run opens an issue with an assignee

- **Severity:** must
- **Principle:** P8
- **Check:** a scheduled full run without a step that opens or updates an assigned issue when it fails (the govengers `nightly-alert.yml`); an alert that only mails whoever last edited the workflow; an issue the next green full run of the same workflow and ref leaves open; a full run and the pushes of a branch in one concurrency group.

What leaves the hot path (TST-018) is checked nowhere else, so a silent red nightly is an unchecked rule. Where it bit: a journey of the full set was red for six nights and nobody was told; GitHub mails a failed scheduled run only to whoever last edited the schedule. The alert keeps one issue per workflow and ref: a red full run opens it and assigns it, every further red run comments on it, and the next newer green full run of the same ref closes it, so the open issues are exactly the red refs. Full runs and pushes sit in separate concurrency groups (`ci-${{ github.ref }}-${{ github.event_name }}`): a nightly never delays a push, and a push never cancels a nightly. The caller job and the assignees variable (`CI_ALERT_ASSIGNEES`) are in the README of govengers/.github.
