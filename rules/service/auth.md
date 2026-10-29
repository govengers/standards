# Authentication and authorization (`AUTH`)

Profile: service. Libraries: `govengers/basicauth` (sessions), `govengers/oidc-auth` (OIDC forward auth), both being merged into `govengers/auth`.

### AUTH-001 Use the org auth libraries, never hand-rolled crypto

- **Severity:** must
- **Principle:** P2, P6
- **Check:** custom password hashing, session cookie signing, JWT parsing or token comparison with `==`.

`basicauth` provides Argon2id hashing with random salts, constant-time comparison, HttpOnly + Secure + SameSite=Lax cookies and user enumeration protection. Behind Traefik, OIDC forward auth issues short-lived RS512 JWTs per request; backends verify them against the JWKS endpoint.

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
HasOIDCRole(role)
HasOIDCGroup(group)

if !authorization.Any(authorization.IsAdmin(), authorization.HasUserID(id)).Check(ctx) {
    return nil, model.ErrPermissionDenied // the controller answers 403 (API-002)
}
```

High-level checkers include the authentication and active checks, so a deactivated admin is not an admin.

### AUTH-004 Checkers take `context.Context`, not `*gin.Context`

- **Severity:** should
- **Principle:** P3, P9
- **Check:** authorization functions with a `*gin.Context` parameter.

The same checker then works in HTTP handlers, WebSocket broadcast filters, background jobs and tests, which build the context with the actor and nothing else.

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

The auth library's `UserTransformer` loads the full user through the (cached) user repository on each request, so deactivations and role changes take effect immediately.

### AUTH-008 Seed the first admin only when none exists

- **Severity:** must
- **Principle:** P6
- **Check:** a default admin with a hard-coded password; seeding that resets an existing admin's password on every start.

The initial admin password comes from a `.Sensitive()` config value and is used only when no active user exists.
