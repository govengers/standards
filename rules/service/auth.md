# Authentication and authorization (`AUTH`)

Profile: service. Library: [`github.com/govengers/auth`](https://github.com/govengers/auth): password with TOTP, OIDC and GitHub login, server-side sessions (memory, Redis, PostgreSQL), API keys, impersonation, dev login, authorization checks and sealing of secrets at rest.

### AUTH-001 Use govengers/auth, never hand-rolled crypto

- **Severity:** must
- **Principle:** P2, P6
- **Check:** custom password hashing, session handling, API key issuing, JWT parsing, encryption of secrets at rest or token comparison with `==`; an auth library other than `govengers/auth` (the archived `go-basicauth`, `oidc-fwd-auth` and `github-fwd-auth` included).

`govengers/auth` provides Argon2id hashing with random salts, constant-time comparison, server-side sessions whose cookie holds a random ID only (HttpOnly, Secure, SameSite=Lax), user enumeration protection, per-user API keys capped by their scopes, a dev login that is local-only by default, and the `seal` key ring for secrets at rest (TOTP secrets, webhook signing secrets). Its PostgreSQL stores take the caller's transaction (`WithExecutor`), so a key or a credential commits with the application's own rows and audit entry (INT-001). For apps without code of their own, the `forwardauth` image answers Traefik's forward-auth checks and passes the identity on as a signed RS512 JWT that Go backends verify with `jwt.Verifier`.

### AUTH-002 Authorize every non-public route explicitly

- **Severity:** must
- **Principle:** P6, P8
- **Check:** a route that reads or mutates data with no authorization check in the handler, the route group middleware or the service it calls; public routes not listed in the auth path rules.

Authentication says who; authorization says whether. A logged-in user is not automatically allowed to see another user's data.

### AUTH-003 Build permissions from composable checkers

- **Severity:** should
- **Principle:** P1, P8
- **Check:** role checks written inline (`user.Role == "admin"`) in handlers or services instead of the shared checkers.

```go
IsAuthenticated()   // logged in
IsActive()          // active flag set
IsUser()            // active user
IsAdmin()           // active admin
HasUserID(id)       // active user with this ID
HasRole(role)
HasOIDCRole(role)
HasOIDCGroup(group)
HasGitHubTeam(team)
HasPermission(resource, access) // API key scopes such as builds:write

if err := authorization.Any(authorization.IsAdmin(), authorization.HasUserID(id))(ctx); err != nil {
    return nil, err // a refusal is an *auth.Error: the controller answers 401 or 403 (API-002)
}
```

These are `govengers/auth/authorization`'s checks, combined with `All`, `Any` and `Not`. A check is a function of the context: `nil` allows, an error refuses. Return the refusal unchanged; `auth.ResponseFor` (and livewire, which uses it) answers `auth.ErrUnauthenticated` with 401, `auth.ErrForbidden` with 403 and a wiring mistake (a nil check, `Any` without checks) with 500, so it fails closed. High-level checkers include the authentication and active checks, so a deactivated admin is not an admin.

### AUTH-004 Checkers take `context.Context`, not `*gin.Context`

- **Severity:** should
- **Principle:** P3, P9
- **Check:** authorization functions with a `*gin.Context` parameter.

The same checker then works in HTTP handlers, WebSocket broadcast filters, background jobs and tests, which build the context with the identity (`auth.WithIdentity`) and nothing else.

### AUTH-005 Data-dependent authorization lives in the service layer

- **Severity:** must
- **Principle:** P6
- **Check:** ownership or membership checks ("owns this resource", "member of this business") only in handlers, so a second entry point (RPC, job, another handler) calling the same service skips them.

| Layer | Checks |
|-------|--------|
| middleware / interceptor | authenticated, active |
| controller | static role gates (admin) |
| service | ownership, membership, anything needing a lookup |

### AUTH-006 Read the actor from context through one helper

- **Severity:** should
- **Principle:** P1, P3
- **Check:** context values read with raw keys or string keys in several places; `context.WithValue` with a built-in type as key.

```go
type contextKey struct{}

func With(ctx context.Context, user *model.User) context.Context {
    return context.WithValue(ctx, contextKey{}, user)
}

func User(ctx context.Context) *model.User {
    user, _ := ctx.Value(contextKey{}).(*model.User)
    return user
}

// ID returns the acting user's ID, or SystemUserID for system operations.
func ID(ctx context.Context) uuid.UUID {
    if user := User(ctx); user != nil {
        return user.ID
    }
    return SystemUserID
}
```

`SystemUserID` is the well-known sentinel (`00000000-0000-0000-0000-000000000000`) for seeds, migrations and webhooks.

### AUTH-007 Load the current user fresh, from the cache

- **Severity:** should
- **Principle:** P6
- **Check:** user role or active flag taken from the session or token payload and trusted for longer than one request.

The session holds who logged in (`auth.Identity`), not what the application lets them do. A middleware behind `session.Guard` loads the application's user by the identity through the (cached) user repository on each request and puts it into the context (AUTH-006). Because AUTH-003's checks read the identity, the middleware also replaces the identity in the context (`auth.WithIdentity`) with one carrying the user's current active flag, roles and permissions, so deactivations and role changes take effect immediately. The Guard's `Refreshers` re-check the login itself once per `RefreshInterval` (a deleted user, a changed password, a removed team ends the session).

### AUTH-008 Seed the first admin only when none exists

- **Severity:** must
- **Principle:** P6
- **Check:** a default admin with a hard-coded password; seeding that resets an existing admin's password on every start.

The initial admin password comes from a `.Sensitive()` config value and is used only when no active user exists.
