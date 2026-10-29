# Review protocol

How a review agent measures a Go repo or a change against these standards.

## 1. Pin the version

Review against a tagged version of this repo and state it in the report (`standards@v1.2.0`). A rule change must not silently change the verdict on old code.

## 2. Determine the rule set

1. Read `.govengers.yml` in the repo root. `profile` selects the rule set, `exceptions` lists rules that are waived with a reason.
2. No `.govengers.yml`: a repo with a `cmd/` entry point that serves traffic or runs as a process is `service`, everything else is `library`. Say in the report that the profile was inferred.
3. Apply `rules/core/` plus the profile's directory. Skip deprecated rules.

## 3. Scope

- **Change review (PR, diff):** grade only the changed lines and what they directly break. Pre-existing violations in untouched code are out of scope; list at most a handful under "Noticed, not graded".
- **Repo audit:** grade everything except generated code (`internal/repository/internal/sqlc`, `*_gen.go`, files headed `Code generated ... DO NOT EDIT.`).

## 4. Run the machines first

If the toolchain is available, run `golangci-lint run` with [.golangci.yml](.golangci.yml), `go vet ./...`, `go test -race ./...` and the end-to-end suite (`just test-e2e`). Report lint, vet and unit test failures as-is under rule `TCH-004`, end-to-end failures under `TST-011`. Do not restate what lint already reports as separate rule findings.

## 5. Grade

For each rule in the set, look for the pattern described in its **Check** line. A finding needs evidence: a file and line, and the code that violates the check. No evidence, no finding.

- An exception in `.govengers.yml` waives the rule for the whole repo.
- A `should` rule with a reason given in a comment at the site counts as compliant.
- Do not invent rules. Something that looks wrong but matches no rule goes under "Rule candidates".

## 6. Report

```markdown
## Verdict: FAIL   (standards@v1.2.0, profile: service)

| Severity | Count |
|----------|-------|
| must     | 2     |
| should   | 3     |

### Findings

- **ERR-002** (must) `internal/repository/user.go:48`
  Compares `err.Error()` with "no rows in result set".
  Fix: map `pgx.ErrNoRows` to `ErrNotFound` in `mapError` and match with `errors.Is`.

### Rule candidates
- `internal/server/upload.go:30` - reads the whole multipart body into memory; no rule covers request size limits yet.

### Noticed, not graded
- ...
```

- **Verdict:** `FAIL` if any `must` finding exists, `PASS WITH NOTES` if only `should` findings exist, `PASS` otherwise.
- Order findings by severity, then by file.
- Each finding: rule ID, severity, `file:line`, what the code does, the concrete fix.
- **Rule candidates** are how the standards grow: they are proposed as new rules via [CONTRIBUTING.md](CONTRIBUTING.md).
