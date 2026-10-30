# Manifesto

What we believe about building software in Go. These are not graded directly; the [rules](rules/) are. Every rule names the principle it serves, and every principle is backed by rules. A principle without rules is a slogan, a rule without a principle is arbitrary.

## P1 - Clean code is the product

Code is read far more often than it is written, by people and by agents. Names say what a thing is, spelled out, never abbreviated. A function does one thing, at one level of abstraction, and changes nothing its name does not announce. Code explains itself through its names: a comment that explains what the code does means a name is wrong. Comments say why, warn, or document a public contract; not every function needs one. Packages hide their internals. We leave every piece of code we touch in a better state than we found it. Working but unreadable code is unfinished.

## P2 - Boring beats clever

The standard library first, a well-known dependency second, our own abstraction last. No interface with one implementation, no factory for one product, no framework where a function will do. Clever code is what someone has to decode at 3 AM.

## P3 - Explicit over implicit

Dependencies are passed in, not reached for. Every component is built from an options struct, and `main()` wires every layer in a visible order: controllers translate a transport, services hold the business logic, repositories persist, clients talk to other systems. Configuration is read once, in `main`. No `init()` side effects, no global singletons, no reflection-driven magic. If you cannot see it in the code, you cannot review it.

## P4 - Errors are values, handled once

An error is returned with context, matched by identity rather than by string, and handled at exactly one place - which is also the one place it gets logged. Panics are for programmer errors and startup misconfiguration, never for control flow.

## P5 - The database guards the invariants

Data outlives code. Uniqueness, required fields, enums and value ranges live in the schema as constraints, so no code path can skip them. Queries are SQL you can read, checked against the schema at generate time.

## P6 - Fail fast at startup, degrade gracefully at runtime

A misconfigured service crashes on boot, not at 3 AM under load. Once running, it bounds every wait, retries only what is safe to retry, and keeps serving when an optional dependency is down.

## P7 - Every change leaves a trace

Mutations are audited and broadcast. Each unit of work emits one rich, structured wide event, and every failure and every business or technical interaction on every layer is recorded on it. Every service exports the rate, errors and duration of its requests and dependencies as metrics, so dashboards and alerts never depend on reading logs. When something goes wrong in production, the answer is in the data, not in a guess.

## P8 - Let the machine check it

What a compiler, linter, code generator or test can enforce, a human or agent should not have to remember. We prefer designs where the wrong thing does not compile: `internal/` packages for boundaries, typed constants for enums, generated code for queries.

## P9 - Tests ship with the feature

New behavior arrives with the test that proves it. Business decisions are pure functions with table tests, unit coverage stays high, and an end-to-end suite runs against the built artifact and must be green before a merge. Tests run against real dependencies where it matters (a real Postgres, a real HTTP server), because mocks that diverge from production hide the bugs we care about.

## P10 - One artifact, containerized

A service ships as one static binary in one minimal container image, configured by the environment. What runs in production is what was built and tested in CI.
