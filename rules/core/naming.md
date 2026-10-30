# Naming (`NAM`)

Profile: core

### NAM-001 Spell every name out; no abbreviations

- **Severity:** must
- **Principle:** P1
- **Check:** a name we chose (variable, parameter, named result, field, function, method, type, constant, package, environment variable) that shortens a word (`repo`, `cfg`, `opts`, `params`, `req`, `resp`, `res`, `srv`, `svc`, `msg`, `tx`, `idx`, `fn`, `pgErr`, `errCh`, `shutdownCtx`), or a single-letter name, unless it is in the allowed list below. Comments and prose are not graded; generated code is out of scope. `varnamelen` flags short names used beyond the next line; the rest is review.

A name is read a hundred times and typed once, and autocomplete types the long version for free. An abbreviation is a private dictionary: `res` is a result, a response or a resource depending on who wrote it. Spelled-out names are also unambiguous to search for, for people and for agents.

Allowed, and nothing else:

| Allowed | Where | Why |
|---------|-------|-----|
| one or two letters (`s *UserService`, `c *ProductController`) | method receivers, the same on every method of a type | Go convention; methods stay short (FUN-004) |
| one capital letter (`T`, `K`, `V`) | type parameters | Go convention |
| `ctx`, `err` | a `context.Context`, an `error` | the full words shadow the `context` package and the `error` type. Compound names spell out: `shutdownContext`, `closeError` |
| `t`, `b`, `f`, `m`, `tb` | `*testing.T`, `*testing.B`, `*testing.F`, `*testing.M`, `testing.TB` | fixed by `go test` convention |
| the `Err`/`err` prefix (`ErrNotFound`, `errNoChange`) | sentinel error variables | Go convention, enforced by `errname` |
| initialisms that are the standard name of the thing: Go's common initialisms (`ID`, `URL`, `URI`, `HTTP`, `JSON`, `SQL`, `UUID`, `API`, `UI`, `TLS`, `TTL`, `DNS`, `TCP`) and protocol or product names written that way (`OIDC`, `JWT`, `TOTP`, `NPM`, `AWS`) | anywhere, cased per NAM-002 | nobody spells them out; shortened words (`Max`, `Min`, `Util`, `Diff`) are not initialisms |
| `email`, `admin`, `ok` | anywhere | words in their own right |
| `we`, `e2e`, `dev` | a wide event (NAM-007), the end-to-end suite (`test/e2e`, `E2E_BINARY`), development mode (`DevMode`, `DEV_MODE`) | org vocabulary by decision (29.10.2026): `we.Success()` reads like a sentence |
| names we do not own | imported package names (`fmt`, `strconv`, `pgx`), methods of interfaces we implement (`ServeHTTP`), identifiers in generated code, names fixed by another system (a provider's JSON field, a library's option) | not ours to change |

| Instead of | Write |
|------------|-------|
| `repo`, `svc`, `ctrl` | the role: `userRepository`, `userService`, `userController` |
| `cfg`, `conf`, `opts` | `configuration`, `options` |
| `params`, `args` | `parameters`, `arguments` |
| `req`, `resp`, `res` | `request`, `response`, `result` |
| `srv` | `apiServer`, `testServer` |
| `msg`, `tx`, `buf`, `tmp` | `message`, `transaction`, `buffer`, a name for what it holds |
| `i`, `idx`, `k`, `v` | `index`, `key`, `value` |
| `c *gin.Context` | `ginContext *gin.Context` |
| `w`, `r` in an `http.HandlerFunc` | `writer`, `request` |
| `mu`, `wg`, `g` (errgroup) | `mutex`, `waitGroup`, `group` |
| `fn`, `cb` | the role: `operation`, `onComplete` |
| `tc`, `tt` in table tests | `testCase` |
| `pgErr`, `closeErr`, `lastErr` | `postgresError`, `closeError`, `lastError` |
| `orgID`, `MaxConns`, `diff`, `util` | `organizationID`, `MaximumConnections`, `changes`, a name for what it provides |

A variable named after its package shadows the package (`repository := repository.New...`). Name the role instead: `productRepository`.

```go
// bad
func (s *Server) procReq(c *gin.Context) {
    repo := s.opts.Repo
    res, err := repo.Get(c.Request.Context(), id)
    ...
}

// good
func (c *UserController) getUserHandler() gin.HandlerFunc {
    return func(ginContext *gin.Context) {
        id, err := idParameter(ginContext)
        ...
        user, err := c.options.UserService.Get(ginContext.Request.Context(), id)
        ...
    }
}
```

### NAM-002 Write initialisms in one case

- **Severity:** must
- **Principle:** P1
- **Check:** `Id`, `Url`, `Http`, `Json`, `Api`, `Uuid`, `Sql`, `Oidc` inside identifiers (`userId`, `getIdUrlParameter`, `UuidPointer`, `ApiBaseUrl`).

Go convention, enforced by `revive` var-naming in most cases. Struct tags and SQL column names are not identifiers and follow the wire format (`json:"userId"` is fine).

```go
// bad
func getIdUrlParameter(c *gin.Context) (uuid.UUID, error)
ApiBaseUrl string

// good
func idParameter(ginContext *gin.Context) (uuid.UUID, error)
APIBaseURL string
```

### NAM-003 Do not repeat the package name

- **Severity:** should
- **Principle:** P1
- **Check:** exported names that stutter with their package (`repository.RepositoryOptions`, `cache.CacheKey`, `user.UserService`).

Callers read `pkg.Name`; the package already says what domain it is.

```go
// bad
cache.NewCache(&cache.CacheOptions{})

// good
cache.New(&cache.Options{})
```

Exception: a layer package holds one component kind per business object (ARC-001), and its types carry the kind as a suffix: `service.UserService`, `controller.UserController`, `repository.UserRepository`. The bare `service.User` would read as a user, and `service.NewUser` as creating one.

### NAM-004 Name interfaces by behavior, without prefixes

- **Severity:** must
- **Principle:** P1
- **Check:** interfaces named `IStorage`, `StorageInterface`, `UserServiceImpl` for the implementation.

```go
// bad
type IStorage interface { ... }

// good
type Storage interface { ... }
type UserProvider interface { UserByID(ctx context.Context, id uuid.UUID) (*model.User, error) }
```

### NAM-005 Keep package names short, lowercase, and specific

- **Severity:** should
- **Principle:** P1, P2
- **Check:** packages named `util`, `common`, `helpers`, `misc`, `base` that collect unrelated code; package names with underscores or mixed case.

A `util` package becomes the place everything goes to hide, and `util` is an abbreviation (NAM-001). Name the package by what it provides (`actor`, `pagination`). Short means one word, not an abbreviated one.

```go
// bad
util.GetActorID(ctx)
util.StringPointer("x")

// good
actor.ID(ctx)
new("x") // Go 1.26
```

### NAM-006 Getters drop the `Get` prefix

- **Severity:** should
- **Principle:** P1
- **Check:** methods `GetName()`, `GetID()` that only return a field. Data-access methods that perform a lookup (`Get(ctx, id)` on a repository or service) are not getters and keep the verb.

```go
// bad
func (u *User) GetEmail() string { return u.email }

// good
func (u *User) Email() string { return u.email }
```

### NAM-007 Variables holding a wide event are called `we`

- **Severity:** should
- **Principle:** P1
- **Check:** a `*wideevent.Event` variable named `wideEvent`, `event`, `e`, `evt` or `logEvent`.

One name across the org makes `we.Success()` and `we.Failure(err)` instantly recognizable in any repo, and `event` stays free for the realtime package.

### NAM-008 Name what a value means, not its type

- **Severity:** should
- **Principle:** P1
- **Check:** a type or container encoded into a name (`userSlice`, `userList`, `nameString`, `idMap`, `countInt`, `userStruct`, `pointerToUser`) where the meaning is available instead (`users`, `name`, `usersByID`, `count`, `user`).

The compiler and the editor know the type; the name says what the value is for. When one value exists in two representations in the same scope, naming the representation is the meaning: `rawBody` and `body`, `idText` and `id`.

```go
// bad
userMap := make(map[uuid.UUID]*model.User, len(userSlice))

// good
usersByID := make(map[uuid.UUID]*model.User, len(users))
```

### NAM-009 Distinct names mean distinct things

- **Severity:** should
- **Principle:** P1
- **Check:** noise words that add no meaning to a name (`userData`, `UserInfo`, `productObject`, `theUser`, `orderStuff`); names that differ only by a number or a noise word (`user1` and `user2`, `UserInfo` next to `UserData`); type names ending in `Manager`, `Processor` or `Helper` that hide what the type does.

If two names exist, a reader assumes two different things. `UserInfo` and `UserData` force them to read both to learn the difference. Name the difference instead: `UserProfile` and `UserCredentials`, `buyer` and `seller`, `previousUser` and `updatedUser`.

```go
// bad
func transfer(account1, account2 *model.Account, amountCents int64) error

// good
func transfer(source, destination *model.Account, amountCents int64) error
```

### NAM-010 Name magic values with constants

- **Severity:** should
- **Principle:** P1
- **Check:** a number or string literal in a condition, calculation or call whose meaning the line does not state (`if len(lines) > 100`, `status == "A"`, `time.Sleep(3 * time.Second)` inside business logic); the same meaningful literal repeated in several functions. Not findings: `0`, `1`, `-1` and `2` in obvious arithmetic, a literal assigned to a named field, option or constant (`ReadHeaderTimeout: 5 * time.Second`), format strings, test data.

The constant's name tells the reader what the number means, and it is the one place to change it. Closed sets of values become typed constants (DES-009).

```go
// bad
if len(input.Lines) > 100 {
    return fmt.Errorf("%d lines: %w", len(input.Lines), model.ErrInvalid)
}

// good
const maximumLinesPerOrder = 100

if len(input.Lines) > maximumLinesPerOrder {
    return fmt.Errorf("%d lines: %w", len(input.Lines), model.ErrInvalid)
}
```
