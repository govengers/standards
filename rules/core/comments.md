# Comments (`CMT`)

Profile: core

Code explains itself through its names. A comment that explains what the code does means a name is wrong: fix the name, then delete the comment. Comments are for what the code cannot say: why it is this way, what breaks if you change it, and the contract of a public API. Not every function needs a comment in front of it.

### CMT-001 Let names explain the code; delete comments that restate it

- **Severity:** must
- **Principle:** P1
- **Check:** a comment that restates what the code next to it does (`// get the user`, `// loop over the lines`, `// return the result`); a comment that carries what a name should say (`timeout int // in seconds`, `// true if the user may sign in` above a boolean); noise that git or the editor already records: section banners (`// ===== helpers =====`), closing-brace markers (`} // end for`), bylines (`// added by ...`) and change journals (`// 03.10.2026: fixed ...`).

A comment that restates the code doubles what a reader has to read and is the first thing to go stale when the code changes (CMT-004). When the code needs a comment to be understood, the code is at fault: rename the variable, extract the step into a function named after it (FUN-003), or name the condition (FUN-006).

What stays worth a comment:

- **Why**, when the code looks wrong but is right, or a constraint comes from outside the code: a provider limit, a bug in a dependency, a legal requirement.
- **A warning of consequences:** "not safe for concurrent use", "order matters: the server stops before the hub (LAY-003)".
- **A reference** to a rule ID, an issue or a specification the code implements.
- **The contract of a library's exported API** (LIB-005, CMT-002).
- **The reason for deviating** from a `should` rule ([REVIEW.md](../../REVIEW.md)), and the reason on a `//nolint` (TCH-004).

```go
// bad: the comments carry what the names should
// check if the user can sign in
if user.Active && !user.Locked && user.ExpiresAt.After(now) {
    // create the session
    session, err := s.options.SessionRepository.Create(ctx, user.ID)
    ...
}

type ClientOptions struct {
    Timeout int // in seconds
}

// good: the names say it, the comment says why
if user.CanSignIn(now) {
    session, err := s.options.SessionRepository.Create(ctx, user.ID)
    ...
}

type ClientOptions struct {
    Timeout time.Duration
}

// The payment provider rejects batches above 100 transfers.
const maximumTransfersPerBatch = 100
```

### CMT-002 A doc comment states what the signature cannot

- **Severity:** should
- **Principle:** P1
- **Check:** a doc comment that only repeats the identifier's name and signature in words (`// NewUserService creates a new UserService.`, `// Get gets a user by ID.`, `// UserID is the user ID.`).

Unexported identifiers and the code of a service need no doc comment: the name is the documentation, and a restating doc comment is CMT-001 noise. Write one only when it adds something a caller cannot read from the signature: an error the caller should match, what a nil or zero argument means, units, ownership, concurrency safety, a side effect worth a warning. A library's exported API is the exception: it is documented in full (LIB-005), and there too the comment carries the contract, not the name in other words.

```go
// bad
// NewUserService creates a new UserService.
func NewUserService(options *UserServiceOptions) *UserService

// Get gets a user by ID.
func (s *UserService) Get(ctx context.Context, id uuid.UUID) (*model.User, error)

// good: in a service, the names are the documentation
func NewUserService(options *UserServiceOptions) *UserService

func (s *UserService) Get(ctx context.Context, id uuid.UUID) (*model.User, error)

// good: in a library, the doc comment carries the contract
// Get returns the value stored under key, or false if it is missing or expired.
// It is safe for concurrent use.
func (c *Cache[K, V]) Get(key K) (V, bool)
```

### CMT-003 Delete code instead of commenting it out

- **Severity:** must
- **Principle:** P1, P8
- **Check:** enforced by gocritic's `commentedOutCode` in [.golangci.yml](../../.golangci.yml).

Commented-out code is never compiled, never tested and never deleted, because nobody knows whether it is still needed. Git keeps every version: delete it.

### CMT-004 Keep comments true

- **Severity:** must
- **Principle:** P1
- **Check:** a comment that contradicts the code it describes (a doc comment naming a parameter, error, default or behavior the code no longer has); in a change review, changed code whose comment still describes the old behavior, including comments elsewhere in the repo that repeat the changed claim.

A wrong comment is worse than none: a reader trusts it over the code, and an agent copies it into the next change. Update or delete the comment in the same change as the code. When a claim turns out wrong, search the repo for every comment that repeats it.

```go
// bad: the code returns ErrNotFound, the comment still promises nil
// Get returns nil if the user does not exist.
func (s *UserService) Get(ctx context.Context, id uuid.UUID) (*model.User, error)

// good: delete it (CMT-002) or make it true
// Get returns model.ErrNotFound if the user does not exist or was deleted.
func (s *UserService) Get(ctx context.Context, id uuid.UUID) (*model.User, error)
```

### CMT-005 A TODO names its issue

- **Severity:** should
- **Principle:** P1
- **Check:** a `TODO`, `FIXME` or `XXX` comment without an issue reference.

A TODO without an issue is a wish nobody tracks. Open the issue and reference it, or do the work now.

```go
// bad
// TODO: handle pagination

// good
// TODO(#142): page through the provider's results once accounts have more than 100 repositories.
```
