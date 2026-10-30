---
name: govengers-review
description: "Static code review of a Go repo or a change (PR, branch, commits since a ref) against the govengers/standards rules, following the standards' REVIEW.md. Loads the latest released standards ad hoc (or the version the user names), runs the lint/vet/test machines, then fans the rule files out to parallel Sonnet review agents, one per topic bucket, and verifies and merges their findings into one graded report with rule IDs. Use on 'govengers review', 'review against the standards', 'standards review', 'check this against govengers', or any review request in a repo with a .govengers.yml."
---

# govengers review: standards in, graded findings out

A static review: every finding is a rule ID, a `file:line` and the code that breaks the rule's
**Check**. Architecture and design debates are not this skill's job; use `dual-review` for an
adversarial correctness review.

Read-only throughout: no edits, commits, pushes or checkouts in the reviewed repo.

## Input

- **Target:** a PR (`#42`, a URL), a branch, or a ref (compared as `<ref>...HEAD`). No target: the
  current branch against `origin/main`, uncommitted changes included. `audit`: the whole repo.
- **Standards version** (optional): `standards=<tag|branch|sha|path>`. Default: the newest
  `v*` tag of `github.com/govengers/standards`. A path uses a local checkout as it is on disk.

## 1. Load the standards

```sh
STANDARDS_REPO=https://github.com/govengers/standards.git
REF=<requested ref, or:> $(git ls-remote --tags --refs "$STANDARDS_REPO" 'v*' | sed 's#.*refs/tags/##' | sort -V | tail -1)
STANDARDS=${TMPDIR:-/tmp}/govengers-standards/$REF
```

- **Tag:** tags are immutable (org ruleset), so reuse `$STANDARDS` if it exists, otherwise
  `git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$REF" "$STANDARDS_REPO" "$STANDARDS"`.
- **Branch:** always fresh: `rm -rf "$STANDARDS"` first, then the same clone.
  Version string: `standards@<branch> (<short sha>)`.
- **SHA:** `git init -q "$STANDARDS" && git -C "$STANDARDS" fetch -q --depth 1 "$STANDARDS_REPO" <sha> && git -C "$STANDARDS" checkout -q FETCH_HEAD`.
- **Path:** `STANDARDS=<path>`, version `standards@local:<path> (<short sha>, dirty if git status is not clean)`.

Never fall back silently to another version. If the fetch fails, stop and say so.

Read `$STANDARDS/REVIEW.md` now. It is the protocol; this skill only adds the fan-out. Where they
differ, REVIEW.md of the loaded version wins.

## 2. Pin the target

```sh
git fetch origin
# PR (GitHub): gh pr view <n> --json number,title,baseRefName,headRefOid,url
git fetch origin "refs/pull/<n>/head:refs/remotes/origin/pr-<n>"    # BASE=origin/<baseRefName>, HEAD_REF=origin/pr-<n>
# branch or ref: BASE=<ref>, HEAD_REF=HEAD
EXCLUDE=$(git rev-parse --git-path info/exclude); mkdir -p .reviews "$(dirname "$EXCLUDE")"
git check-ignore -q .reviews || echo '.reviews/' >> "$EXCLUDE"
git diff "$BASE...$HEAD_REF" > .reviews/<slug>.diff           # plus `git diff HEAD` when the tree is dirty
git diff --name-only "$BASE...$HEAD_REF" > .reviews/<slug>.files
```

`<slug>`: `pr-<n>`, the kebab-cased branch name, or `audit`. Audit: `.reviews/audit.files` lists
every tracked file. In both modes drop generated files: anything under
`internal/repository/internal/sqlc`, `*_gen.go`, and files whose header matches
`^// Code generated .* DO NOT EDIT\.$`. Empty diff: stop, nothing to review.

## 3. Determine the rule set

As REVIEW.md step 2: `profile` and `exceptions` from `.govengers.yml`; without it, a repo with a
`cmd/` entry point that serves traffic or runs as a process is `service`, everything else
`library` (say "inferred" in the report). Rule set: `rules/core/` plus `rules/<profile>/`.

## 4. Run the machines

The main session runs them, never the review agents. Lint first, because the agents need its output:

```sh
golangci-lint run -c "$STANDARDS/.golangci.yml" ./... > .reviews/<slug>-lint.txt 2>&1      # change review: add --new-from-rev "$BASE"
```

Library profile: the baseline turns revive's doc-comment checks off, so run a second pass with
them on (LIB-005) and append it:

```sh
golangci-lint run --default=none --enable=revive -c <(sed -E '/disable-checks-on-/d; /name: exported/{n;/arguments:/d;}; s/^(        - name: exported).*/\1\n        - name: package-comments/' "$STANDARDS/.golangci.yml") ./... >> .reviews/<slug>-lint.txt 2>&1
```

Then, in the background while the agents work: `go vet ./...`, `go test -race ./...`, and
`just test-e2e` if the justfile has that recipe. A tool that is missing or fails to start is
reported as "not run" with the reason, never as green.

## 5. Fan out the review agents

Buckets, by topic. Spawn every bucket of the profile in **one message** so they run in parallel:
`Agent` tool, `subagent_type: general-purpose`, `model: sonnet`, fresh context.

| Bucket | Rule files | Profile |
|--------|-----------|---------|
| readability | `core/naming.md`, `core/functions.md`, `core/comments.md`, `core/design.md` | all |
| errors | `core/errors.md`, `core/concurrency.md`, `core/resilience.md` | all |
| tests-toolchain | `core/testing.md`, `core/toolchain.md` | all |
| library | `library/library.md` | library |
| architecture | `service/architecture.md`, `service/layout.md`, `service/configuration.md`, `service/api.md`, `service/auth.md`, `service/deployment.md` | service |
| data | `service/data-access.md`, `service/data-integrity.md`, `service/jobs.md` | service |
| observability | `service/logging.md`, `service/metrics.md`, `service/observability.md`, `service/realtime.md` | service |

Then list `$STANDARDS/rules/core/*.md` and `$STANDARDS/rules/<profile>/*.md`: every file must be
in exactly one bucket. A file the table does not know (a newer standards version) joins the bucket
of its closest topic; a file the table names that does not exist is dropped. Say both in the report.

Why buckets and not one agent per rule file: every agent reads the same code, so per-file agents
multiply that cost twenty times for small rule files, and rules that interact (FUN-003 and
CMT-001, ERR-003 and LOG-002) belong in one head. Why not one agent: 3000 lines of rules dilute
its attention. Ceiling: an audit of a repo with more than about 15k lines of non-generated Go
splits each bucket's file list in two by top-level directory; say so in the report.

Brief (fill the angle brackets; one per bucket):

```
Static review of <repo path> against the govengers standards, bucket <bucket>.
READ-ONLY: read files and grep, nothing else. No edits, no git commands that change state,
no builds or tests (the main session ran them).

Standards: <$STANDARDS> (<version string>). Read <$STANDARDS>/REVIEW.md sections 3 and 5, then
these rule files in full: <rule file paths>. Grade ONLY the rules in these files. Skip deprecated
rules and these waived ones: <exceptions from .govengers.yml with reasons, or "none">.
Profile: <profile>.

Scope: <change review: the diff in .reviews/<slug>.diff and the files in .reviews/<slug>.files;
grade only the changed lines and what they directly break, read the whole changed function for
context | audit: every file in .reviews/audit.files>.
Lint already reported what is in .reviews/<slug>-lint.txt. Do not restate those as findings.

For each rule, look for the pattern in its Check line. A finding needs evidence: the file, the
line, and the offending code quoted verbatim. No evidence, no finding. A `should` rule with a
reason in a comment at the site is compliant. Severity is the rule's, never yours. Something that
looks wrong but matches no rule in your files goes under Rule candidates, not Findings.

Answer in exactly this markdown, "none" under an empty heading:

### Findings
- **<RULE-ID>** (<must|should>) `<path>:<line>`
  Evidence: `<verbatim code>`
  Problem: <one sentence: what the code does against the Check>
  Fix: <one sentence: the concrete change>

### Rule candidates
- `<path>:<line>` - <what looks wrong and why no rule in your files covers it>

### Noticed, not graded
- `<path>:<line>` - <pre-existing violation outside the change, at most five>
```

## 6. Verify and merge

The main session, before anything reaches the report:

1. **Evidence check:** for every finding, open `<path>:<line>` and confirm the evidence is there
   (`grep -nF` is enough for `should`, read the surrounding code for every `must`). No match:
   drop it.
2. **Check match:** for every `must`, reread the rule's Check and confirm the code fits it. A
   `must` fails the whole review, so a doubtful one is dropped, never downgraded.
3. **Scope:** in a change review, a finding outside the changed hunks that the change does not
   directly break moves to "Noticed, not graded" (keep at most five overall).
4. **Duplicates:** the same line under the same rule from two buckets is one finding. The same
   line under two rules stays twice only if both Checks match.
5. **Waivers:** drop findings for rules in `exceptions`.
6. **Machines:** lint, vet and unit test failures go in under `TCH-004`, end-to-end failures under
   `TST-011`, as REVIEW.md step 4 says; summarize lint by linter with counts and list the issues.
7. **Rule candidates:** merge, dedupe, keep the ones that name a real pattern.

## 7. Report

The REVIEW.md step 6 format of the loaded version, with this header:

```markdown
## Verdict: <FAIL | PASS WITH NOTES | PASS>   (<version string>, profile: <profile>[, inferred])

Target: <PR #n / branch / base...head / audit>, <n> files. Reviewers: <buckets>, Sonnet.
Machines: lint <n issues | clean | not run: reason>, vet <...>, race tests <...>, e2e <...>.
```

Write it to `.reviews/<slug>-govengers-review.md` and print it. Post to a PR only when asked,
as one comment: `gh pr comment <n> --body-file .reviews/<slug>-govengers-review.md`.
