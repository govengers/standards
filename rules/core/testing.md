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

Mocks hide broken migrations, constraint violations and SQL errors - the bugs that matter at this layer. Use a real Postgres (embedded-postgres or testcontainers), one database per test, migrated by the app's own migrator, dropped in `t.Cleanup`.

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

Shared test databases fail on the second run because of leftover rows. If migrating per test gets slow, clone a migrated template database (`CREATE DATABASE x TEMPLATE migrated`, around 50 ms).

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
- **Check:** `time.Sleep` to wait for async work; assertions on `time.Now()`; real timers of seconds in tests; tests that only pass in a given order or fail under `-count=2`.

Inject a clock or a short interval through the options struct; wait on a channel or poll with a deadline instead of sleeping.

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
test-e2e:
    mkdir -p sandbox/coverage
    go build -cover -o sandbox/server ./cmd/server
    E2E_BINARY={{justfile_directory()}}/sandbox/server GOCOVERDIR={{justfile_directory()}}/sandbox/coverage go test -tags e2e ./test/e2e/... -count=1
    go tool covdata percent -i=sandbox/coverage
```

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
