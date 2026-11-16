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
    ctx := t.Context()
    require.True(t, authorization.IsAdmin().Check(actor.With(ctx, &model.User{Role: model.RoleAdmin, Active: true})))
    require.False(t, authorization.IsAdmin().Check(actor.With(ctx, &model.User{Role: model.RoleUser, Active: true})))
    require.False(t, authorization.IsAdmin().Check(actor.With(ctx, &model.User{Role: model.RoleAdmin, Active: false})))
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

Inject a clock, a short interval or the backoff through the options struct; wait on a channel or poll with a deadline instead of sleeping. A sleep is the most common reason a test breaks its time budget (TST-017).

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
- **Check:** `-count=1` or another flag that disables caching in the default `just test` recipe or the CI unit test step; CI that does not carry the Go build cache from one run to the next; no scheduled full run (`just test-all`, `just test-e2e-all`, every browser journey); a full run that does not shuffle.

`go test` already runs only what changed. It caches each passing package keyed on its compiled test binary and reruns it only when something linked into that binary changes: a change in `internal/service/billing` reruns the tests of billing and of every package that links it, nothing else. That is more precise than selecting packages from a git diff: the key sees through dead code and includes embedded files, `go.mod` and the environment variables the tests read. `-race`, `-coverprofile`, `-json`, `-run`, `-short` and `-v` keep the cache on, and coverage is replayed from it, so the coverage gate (TST-010) still sees every package. `-count=1` turns it off and runs everything, every time.

The cache is only sound for hermetic tests (TST-013) whose inputs stay the same from run to run (TST-019). A flaky test that passed once stays cached until its package changes, so a scheduled full run runs nightly on main and on every `v*` tag: `just test-all` and `just test-e2e-all`, uncached and `-shuffle=on` (TST-005), and every browser journey (TST-020), none of them skipped by a record (TST-015). In CI the govengers reusable workflow restores each job's build and test cache from the newest main run; pushes to main save it, and so does a pull request that found no cache of its Go release and `go.sum`.

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

CI carries `sandbox/e2e-passed` from run to run; the nightly run calls `just test-e2e-all`, which never skips. The browser journeys skip the same way: their key is the server binary they run against (built reproducibly, so it covers Go code, embedded migrations and queries), every tracked file below the frontend directory (`git ls-files ui`), the justfile and the Bun version. The full recipes are in [templates/](../../templates/).

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

### TST-017 Every test stays inside a time budget, read from the test JSON

- **Severity:** should
- **Principle:** P8, P9
- **Check:** `just test` or `just test-e2e-all` without a step that fails the run when one test took longer than the budget (default 5 s with the race detector); a budget read from wall clock or log output instead of the JSON of `go test` (`gotestsum --jsonfile`); a test over the budget without its own budget and a reason in the list the step reads.

A slow test is a defect with a known set of causes: a sleep or a real backoff (TST-005), production cost parameters (Argon2 at production strength costs several seconds per test under `-race`: inject cheap parameters through the options), a server started per test (TST-016), a migration per test. The budget catches each of them the day it is added, instead of the day the suite has become slow. The JSON names every test and subtest with its duration, also for packages replayed from the cache, so the gate sees the whole suite on every run. A parent test counts its sequential subtests.

```just
test_budget := "5s"

# after the tests, in the test recipe
slow="$(go tool gotestsum tool slowest --jsonfile sandbox/unit.json --threshold {{test_budget}})"; if [ -n "$slow" ]; then printf 'tests over the %s budget (TST-017):\n%s\n' "{{test_budget}}" "$slow"; go clean -testcache; exit 1; fi
```

A package replayed from the cache reports the durations of the run that was cached. A test that ran over the budget once on a loaded machine would fail every rerun until its package changes, and in CI every pull request that restores that cache. So the step drops the test cache when it fails (`go clean -testcache`): the next run measures again, at the price of one uncached run.

The allowance list, if a repo needs one, names the package, the test, its own budget and the reason, and stays short: each entry is a test somebody should make faster.

### TST-018 The pipeline has a time budget, and CI fails over it

- **Severity:** should
- **Principle:** P8
- **Check:** a service's pull request pipeline without a budget step; a budget without separate warm and cold limits; a budget that only prints. With the govengers service workflow (`go-service.yml`): `budget-warm-seconds` and `budget-cold-seconds` not set (README of govengers/.github). The library workflow (`go-library.yml`) has no budget inputs yet, so a library on it is not a finding of this check.

A pipeline grows by seconds nobody notices until it takes twenty minutes, and then every change waits for it. The budget makes the growth a failure in the pull request that causes it. Warm means the jobs restored a cache of the same Go release and `go.sum`; cold is a new dependency or toolchain. The default budget of a service is 300 s warm and 480 s cold, failing above 20 % over; a library stays well below. Full runs (nightly, tags) have no budget.

Reference: the first service built on the whole library set (unit, end-to-end and derivation jobs in parallel, PostgreSQL 18, race detector, coverage) measured on GitHub-hosted runners and an M-series laptop:

| Run | Wall clock |
|-----|-----------|
| pull request pipeline, cold caches | 326 s |
| pull request pipeline, warm caches (docs-only change) | 68 s |
| the same with a frontend job (TST-020), its run skipped as unchanged | 119 s |
| `just test` locally, cold (template built, test cache empty) | 8 s for 89 tests; slowest test 3.4 s |
| `just test` locally, nothing changed | 0.9 s, every package from the cache |
| `just test-e2e` locally, without and with a green record | 6.6 s, under 2 s |
| copy of the migrated template per test | 20 to 40 ms |

### TST-019 Test inputs stay the same from run to run

- **Severity:** should
- **Principle:** P8
- **Check:** a test that reads an environment variable whose value changes between runs (a random port, a timestamp, a temporary path); a test that opens a file inside the module that a recipe rewrites before every run; a test server address derived from the process ID or chosen at random and passed through the environment; a launcher started differently in CI and locally (`go run` once, `go tool` the other time), which changes `PATH`.

`go test` keys a cached result on the test binary, every environment variable the binary read with its value, and every file inside the module it opened, by size and modification time (TST-014). One changing input reruns the whole package on every run, silently: nothing fails, CI just gets slower. A shared test server therefore lives at an address derived from the checkout's path (postgrestest's launcher does this), and a test that needs a scratch file writes it into `t.TempDir()`. Check it once after changing a harness: the second `just test` reports every package `(cached)`; `GODEBUG=gocachetest=1 go test ./pkg` lists the inputs.

### TST-020 Pull requests run a handful of browser smoke journeys; every journey runs nightly

- **Severity:** should
- **Principle:** P8, P9
- **Check:** a pull request pipeline that runs more than about five browser journeys; a browser journey for what a component test against a fake API or an API test covers; no tag that selects the pull request set (`@smoke`); the full set not run nightly and on tags; a browser job without a timeout.

A browser journey costs seconds, a browser install and a running server; it also fails for reasons that have nothing to do with the change. Pages and components are tested in a second against a fake of the API (`bun test` with jsdom), the API by the end-to-end suite. The browser proves only that the pieces fit: a pull request runs the smoke journeys (login, the main journey of the core business object), the rest runs nightly and on `v*` tags. The job caches the browser by the lockfile, skips like TST-015 when server and frontend are unchanged, uploads the report on failure, and has a `timeout-minutes`: a hung server must not hold a runner for six hours.

Reference: three smoke journeys take 2.6 s locally including the frontend build. A browser job's first CI run spends 20 s on the browser's install and its caches pay for themselves from the second run.
