# Design (`DES`)

Profile: core

### DES-001 Construct every component with an options struct

- **Severity:** must
- **Principle:** P3, P9
- **Check:** a component (controller, service, repository, client, handler, server, worker: any struct with dependencies or settings) built with positional dependency parameters, with a struct literal outside its package, or by a constructor that reads globals, environment variables or configuration; a constructor not named `New` or `New<Type>`, or not taking `*Options` or `*<Type>Options`; a missing required collaborator or an invalid setting that the constructor accepts and that fails later instead of returning an error; a constructor that writes to the options it received; a component that keeps a pointer to the caller's options or shares a slice or map of settings with the caller.

The options struct lists every dependency and setting in one place, keeps call sites readable and lets a test build the component with other collaborators.

- **Names:** one component per package: `New(options *Options) (*X, error)`. Several: `NewUserService(options *UserServiceOptions) (*UserService, error)`.
- **Fields:** dependencies (other components, consumer-side interfaces, DES-004) and settings as plain values (strings, durations, flags, limits), never pointers. The caller fills the values; in a service that caller is `main`, reading configuration (CFG-006). Library objects and generated helpers built from injected values (`sqlc.New(pool)`) are not components (ARC-006).
- **Constructor:** validates required fields and settings and returns an error, applies defaults to its own copy, and stores that copy unexported. The caller's struct is never modified (FUN-002). The copy is shallow: collaborators are shared on purpose, but slices and maps of settings the component keeps are cloned (`slices.Clone`, `maps.Clone`), so changing the caller's struct after construction has no effect.

```go
// bad
func NewUserService(userRepository *repository.UserRepository, broadcaster Broadcaster, minimumPasswordLength int) *UserService

// good
type UserServiceOptions struct {
    UserRepository        *repository.UserRepository
    Broadcaster           Broadcaster
    MinimumPasswordLength int // default 12
}

type UserService struct {
    options UserServiceOptions
}

func NewUserService(options *UserServiceOptions) (*UserService, error) {
    if options == nil || options.UserRepository == nil || options.Broadcaster == nil {
        return nil, errors.New("user service: UserRepository and Broadcaster are required")
    }
    resolved := *options
    if resolved.MinimumPasswordLength == 0 {
        resolved.MinimumPasswordLength = 12
    }
    if resolved.MinimumPasswordLength < 8 {
        return nil, fmt.Errorf("user service: MinimumPasswordLength %d is below 8", resolved.MinimumPasswordLength)
    }
    return &UserService{options: resolved}, nil
}
```

Methods then read `s.options.UserRepository`. Value objects and pure helpers are not components: `NewMoney(cents int64, currency string)` needs no options struct.

### DES-002 No `init()` functions

- **Severity:** must
- **Principle:** P3
- **Check:** any `func init()` outside generated code. Enforced by `gochecknoinits`.

`init()` runs at import time in an order nobody reads. Do the work in a constructor or in `main()`.

### DES-003 No mutable package-level state

- **Severity:** must
- **Principle:** P3, P9
- **Check:** package-level `var` holding a client, connection, pool, cache, config map, registry, event hub or anything assigned after startup. Constants, sentinel errors, compiled regexes and lookup tables that are never written are fine.

Globals hide dependencies, couple tests to each other and make parallel tests impossible. Pass the dependency in (DES-001). A library that is a process-wide registry by design declares that as an exception in `.govengers.yml`.

```go
// bad
var pool *pgxpool.Pool

func GetUser(ctx context.Context, id uuid.UUID) (*model.User, error) { ... pool.Query(...) }

// good
type UserRepository struct {
    options UserRepositoryOptions // holds the *pgxpool.Pool
}

func (r *UserRepository) Get(ctx context.Context, id uuid.UUID) (*model.User, error) { ... }
```

### DES-004 Define interfaces where they are consumed, and keep them small

- **Severity:** should
- **Principle:** P2, P3
- **Check:** an interface declared next to its only implementation "for mocking"; an interface with one implementation and no second consumer, unless the consumer declares it to keep a dependency pointing down (ARC-002) or to fake an external system in its tests (ARC-005); interfaces with more methods than the consumer calls.

Accept interfaces, return concrete types. The consumer declares the one or two methods it needs; that also breaks import cycles (the `event` package declares `UserProvider`, the repository satisfies it).

```go
// bad: in package repository
type UserRepository interface { GetUser(...); CreateUser(...); UpdateUser(...); DeleteUser(...); ListUsers(...) }

// good: in package event
type UserProvider interface {
    UserByID(ctx context.Context, id uuid.UUID) (*model.User, error)
}
```

### DES-005 No abstraction without a second use

- **Severity:** should
- **Principle:** P2
- **Check:** factories producing one type, generic helpers with one instantiation, config switches for values that never change, layers that only forward calls. A service method between a controller and a repository is exempt (ARC-002).

Write the concrete thing. Extract when the second real caller shows up.

### DES-010 Keep each piece of knowledge in one place

- **Severity:** should
- **Principle:** P1, P2
- **Check:** the same decision logic (a business rule, validation, calculation, permission or error mapping) written out in two or more places; in a change review, the change adds the second copy instead of calling the first. Code that only looks alike (handler skeletons, wiring, test setup) is not a finding.

Two copies of a rule drift: one gets the fix, the other keeps the bug. Extract the rule into a function named after what it decides and call it from both places. Code with the same shape but different knowledge stays separate; merging it couples things that change for different reasons (DES-005).

```go
// bad: the controller and the import job each decide what a valid SKU is
if len(sku) != 8 || !strings.HasPrefix(sku, "SKU") { ... }

// good: one place decides
func validSKU(sku string) bool
```

### DES-006 Encapsulate: export the minimum

- **Severity:** should
- **Principle:** P1, P8
- **Check:** exported fields or functions with no caller outside the package; structs whose invariants can be broken by setting exported fields directly; application code outside `internal/` in a service.

What is unexported can change freely. Put a service's code under `internal/` so nothing outside the module can depend on it.

### DES-007 Use `new(expr)` instead of pointer helper functions

- **Severity:** should
- **Principle:** P2
- **Check:** helpers like `StringPointer`, `BoolPointer`, `UuidPointer`, `ptr.To` in a module on Go 1.26 or later.

Go 1.26 lets `new` take an expression, which makes the helper family obsolete.

```go
// bad
Active: util.BoolPointer(true),
ObjectID: util.UuidPointer(item.ID),

// good
Active: new(true),
ObjectID: new(item.ID),
```

### DES-008 Dispatch on an explicit type, not on string format

- **Severity:** must
- **Principle:** P1, P8
- **Check:** behavior chosen by `strings.HasPrefix`, `strings.Contains` or regex on an identifier or name instead of a dedicated type field or enum.

```go
// bad
if strings.HasPrefix(dependency.Name, "npm:") { ... }

// good
switch dependency.Type {
case DependencyTypeNPM:
case DependencyTypeMaven:
}
```

### DES-009 Typed constants for closed sets of values

- **Severity:** should
- **Principle:** P8
- **Check:** string literals for states, actions, roles or event names repeated across files instead of a named type with constants.

```go
type EventAction string

const (
    EventActionCreate EventAction = "create"
    EventActionUpdate EventAction = "update"
    EventActionDelete EventAction = "delete"
)
```

`exhaustive` then flags switches that miss a case.
