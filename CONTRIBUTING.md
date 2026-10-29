# Contributing

This repo is graded against by a review agent, so a rule must be precise enough to produce a finding someone can act on.

## Rule format

Every rule lives in the file of its prefix and uses exactly this shape:

````markdown
### ERR-004 Wrap errors with context when crossing a layer

- **Severity:** must
- **Principle:** P4
- **Check:** an error returned from another package is passed up with `return err` and no context, where the caller adds information (an ID, the operation) a reader would need.

One or two sentences on why. Mention where it bit us if that is the reason the rule exists.

```go
// bad
return err

// good
return fmt.Errorf("load user %s: %w", id, err)
```
````

- **Heading:** `### <PREFIX>-<NNN> <imperative one-line rule>`.
- **Severity:**
  - `must` - a violation is a defect or breaks a convention the org declared non-negotiable (naming, function shape, layering, options pattern). The review fails.
  - `should` - the default. Deviating needs a reason in the code or in `.govengers.yml`.
- **Principle:** one or more of `P1`-`P10` from [MANIFESTO.md](MANIFESTO.md).
- **Check:** what the reviewer looks for in the code, phrased as an observable pattern. If you cannot write the check, the rule is not ready.
- **Examples:** bad and good, shortest code that shows the difference. Examples follow every other rule in this repo.

## IDs

- Take the next free number in the file. IDs are never renumbered or reused, because past review findings cite them.
- To retire a rule, keep the heading, add `- **Status:** deprecated (<date>, <reason or replacing rule>)` and remove the check. The reviewer skips deprecated rules.
- A new prefix needs a new file and a line in the [README](README.md) index.

## What belongs where

- **Lint-detectable** (unchecked errors, formatting, shadowing, unused code): add a linter to [.golangci.yml](.golangci.yml), not a rule.
- **Judgment the linter cannot make**: a rule here.
- **How-to sequences** (adding an entity end to end): a playbook in [playbooks/](playbooks/). Playbooks are not graded and must not contradict the rules.

## Adding findings from a review or another session

1. Search the rules for an existing rule that covers the finding. If one does, sharpen its check or examples instead of adding a near-duplicate.
2. Generalize: a rule is about a pattern, not about one repo. Strip project names from examples.
3. Pick the profile: does it hold for every Go repo (`core`), only reusable modules (`library`), or only deployable services (`service`)?
4. Pick the severity honestly. `must` only for things that cause bugs, data loss, security holes or outages, or for the non-negotiable conventions in the MANIFESTO.
5. Keep each rule file under ~400 lines. Split by topic before it grows past that.

## Writing style

- Plain English, short sentences. No em dashes.
- Examples compile in spirit: real package names, Go 1.26 idioms.
- Examples follow every rule, above all the naming (NAM-001) and layering (ARC) rules: agents copy them.
