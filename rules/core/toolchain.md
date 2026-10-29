# Toolchain (`TCH`)

Profile: core

### TCH-001 Stay on a supported Go release

- **Severity:** should
- **Principle:** P2
- **Check:** the `go` directive in `go.mod` names a release older than the two most recent ones (currently 1.26 and 1.27); Dockerfile builder images and CI on a different Go version than `go.mod`; a toolchain upgrade that leaves the `go` directive behind.

Only the two newest releases get security fixes. Keep `go.mod`, CI and the Docker builder on the same version. The `go` directive is a behavior switch, not just a minimum: a newer toolchain keeps the old semantics until the directive is raised. Per-iteration loop variables (1.22), garbage-collected unstopped timers (1.23) and container-aware `GOMAXPROCS` (1.25) only take effect with the matching `go` line.

### TCH-002 Pin code generators and dev tools in `go.mod`

- **Severity:** should
- **Principle:** P8, P10
- **Check:** generators and tools (`sqlc`, `goose`, `stringer`, `gotestsum`, `govulncheck`) installed globally or with `@latest` in CI or the justfile; a library with `tool` directives in its `go.mod`.

`go get -tool` records the tool and its version in `go.mod`; everyone runs the same version with `go tool <name>`.

```bash
go get -tool github.com/sqlc-dev/sqlc/cmd/sqlc@v1.31.1
go tool sqlc generate
```

A library pins its tools with `go run <module>@<version>` in the justfile instead: tool requirements land in the library's `go.mod`, become part of every consumer's module graph and can raise the consumer's versions of shared dependencies.

### TCH-003 Commit generated code and check it in CI

- **Severity:** must
- **Principle:** P8
- **Check:** generated Go code that is not committed, or CI that does not fail when regenerating produces a diff.

```bash
go generate ./...
git diff --exit-code
```

### TCH-004 Lint, vet and race-test in CI

- **Severity:** must
- **Principle:** P8
- **Check:** CI without `golangci-lint run` (using this repo's [.golangci.yml](../../.golangci.yml) as the baseline), `go vet ./...` or `go test -race ./...`; `//nolint` without a linter name and a reason.

The reviewer reports lint, vet and test failures under this rule.

```go
// bad
//nolint
// good
//nolint:gosec // G404: jitter does not need a cryptographic RNG
```

### TCH-005 One justfile as the entry point

- **Severity:** should
- **Principle:** P2, P8
- **Check:** no `justfile`, or CI steps that run commands the justfile does not offer (so local and CI checks drift apart).

Standard recipes: `just build`, `just test`, `just lint`, `just generate`, and `just check` running everything CI runs. CI calls the same recipes.

### TCH-006 Format with gofumpt and goimports

- **Severity:** must
- **Principle:** P1, P8
- **Check:** unformatted files. Enforced by the `formatters` section of `.golangci.yml`.

### TCH-007 Keep dependencies few and maintained

- **Severity:** should
- **Principle:** P2
- **Check:** a new dependency for something the stdlib or an existing dependency covers; dependencies archived or without a release in two years; `replace` directives left in a released `go.mod`.

### TCH-008 Scan for known vulnerabilities in CI

- **Severity:** must
- **Principle:** P8
- **Check:** CI without `govulncheck ./...`; `govulncheck` run with `-json`, `-format sarif` or `-format openvex` as the gate.

`govulncheck` only reports vulnerabilities in functions the code actually reaches, so its findings are worth acting on. With `-json`, `sarif` or `openvex` output it exits 0 regardless of findings, so a gate on those formats never fails. Use the default text mode as the gate, and `-mode binary` to scan the shipped binary.

```bash
go tool govulncheck ./...                       # gate: exits 3 on reachable vulnerabilities
go tool govulncheck -mode binary ./out/server   # what actually ships
```
