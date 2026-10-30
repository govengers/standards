# HTTP API (`API`)

Profile: service

### API-001 One error shape for every error response

- **Severity:** must
- **Principle:** P1, P8
- **Check:** error responses built ad hoc (`gin.H{"error": ...}`, `gin.H{"message": ...}`, plain strings, `ginContext.AbortWithError` that lets Gin render its own body) instead of the shared type.

Frontends silently render nothing when the shape differs from what they expect. Success responses return the resource, or `ListResponse[T]` for lists.

```go
type ErrorResponse struct {
    Code    string `json:"code"`    // "invalid_argument", "not_found", "conflict"
    Message string `json:"message"` // safe to show a user
}
```

### API-002 Map errors to status codes in one place, without leaking internals

- **Severity:** must
- **Principle:** P4, P6
- **Check:** handlers each deciding status codes for domain errors with their own `if` chains; `err.Error()` of an internal error sent to the client; 500 for not-found, conflict, validation or permission errors.

Controllers map the `model` sentinel errors (ERR-005) that services and repositories return; they never import the repository to do so (ARC-002).

```go
func respondError(ginContext *gin.Context, err error) {
    ginadapter.FromContext(ginContext).Failure(err) // every error response is recorded, 4xx included [LOG-002]
    status, response := errorResponse(err)
    ginContext.AbortWithStatusJSON(status, response)
}

func errorResponse(err error) (int, ErrorResponse) {
    switch {
    case errors.Is(err, model.ErrNotFound):
        return http.StatusNotFound, ErrorResponse{Code: "not_found", Message: "not found"}
    case errors.Is(err, model.ErrConflict):
        return http.StatusConflict, ErrorResponse{Code: "conflict", Message: "already exists"}
    case errors.Is(err, model.ErrInvalid):
        return http.StatusBadRequest, ErrorResponse{Code: "invalid_argument", Message: "invalid input"}
    case errors.Is(err, model.ErrPermissionDenied):
        return http.StatusForbidden, ErrorResponse{Code: "permission_denied", Message: "forbidden"}
    default:
        return http.StatusInternalServerError, ErrorResponse{Code: "internal", Message: "internal error"}
    }
}
```

### API-003 Controllers are thin

- **Severity:** should
- **Principle:** P1, P3
- **Check:** handlers containing SQL, transaction handling, multi-step business rules or broadcasting logic; a handler calling more than one service method or any repository (ARC-002).

A handler parses input, applies static role gates (AUTH-005), calls one service method, and responds. A controller is a struct built with options (DES-001) that registers its routes on the router the server hands it; handlers are methods returning `gin.HandlerFunc` closures.

```go
type ProductController struct {
    options ProductControllerOptions
}

func (c *ProductController) RegisterRoutes(router gin.IRouter) {
    router.GET("/products", c.listProductsHandler())
    router.GET("/products/:id", c.getProductHandler())
    router.POST("/products", c.createProductHandler())
}

func (c *ProductController) getProductHandler() gin.HandlerFunc {
    return func(ginContext *gin.Context) {
        id, err := idParameter(ginContext)
        if err != nil {
            respondError(ginContext, err)
            return
        }
        product, err := c.options.ProductService.Get(ginContext.Request.Context(), id)
        if err != nil {
            respondError(ginContext, err)
            return
        }
        respond(ginContext, http.StatusOK, product)
    }
}

// respond writes a success response and marks the wide event as successful [LOG-011].
func respond(ginContext *gin.Context, status int, body any) {
    ginadapter.FromContext(ginContext).Success()
    ginContext.JSON(status, body)
}
```

### API-004 Separate payload types; never bind into model or row types

- **Severity:** must
- **Principle:** P5, P6
- **Check:** `ShouldBindJSON` into a `model.*` or `sqlc.*` type, or a service input type (ARC-004); one payload type shared by create and update; a clearable nullable field in an update payload typed as a plain pointer, which cannot tell "absent" from `null`.

Binding into the model lets a client set fields it must not (`role`, `createdBy`, `id`). In update payloads a pointer means "nil = don't change". A field the client may clear (DAT-012) needs a third state, so it uses `Nullable[T]`, and its `Set` flag travels down to the repository's `SetDescription`.

```go
type CreateProductPayload struct {
    Name        string  `json:"name" binding:"required"`
    Description *string `json:"description,omitempty"`
    PriceCents  int64   `json:"priceCents" binding:"gte=0"`
}

type UpdateProductPayload struct {
    Name        *string          `json:"name,omitempty"`
    Description Nullable[string] `json:"description"`
    PriceCents  *int64           `json:"priceCents,omitempty" binding:"omitempty,gte=0"`
}

// Nullable tells an absent field (Set false) from an explicit null (Set true, Value nil).
type Nullable[T any] struct {
    Set   bool
    Value *T
}

func (n *Nullable[T]) UnmarshalJSON(data []byte) error {
    n.Set = true
    if string(data) == "null" {
        n.Value = nil
        return nil
    }
    return json.Unmarshal(data, &n.Value)
}
```

### API-005 Limit request body size

- **Severity:** must
- **Principle:** P6
- **Check:** no global body size limit (middleware with `http.MaxBytesReader`) and no per-route limit on upload routes.

An unbounded body lets one client exhaust memory.

### API-006 Validate and clamp pagination

- **Severity:** must
- **Principle:** P6
- **Check:** `limit` and `offset` parsed with ignored errors; no maximum on `limit`; negative values accepted.

```go
type ListResponse[T any] struct {
    Limit  int `json:"limit"`
    Offset int `json:"offset"`
    Total  int `json:"total"`
    Items  []T `json:"items"`
}

const maximumLimit = 500

func paginationParameters(ginContext *gin.Context) (model.Pagination, error) {
    limit, err := strconv.Atoi(ginContext.DefaultQuery("limit", "100"))
    if err != nil || limit < 1 {
        return model.Pagination{}, fmt.Errorf("limit: %w", model.ErrInvalid)
    }
    offset, err := strconv.Atoi(ginContext.DefaultQuery("offset", "0"))
    if err != nil || offset < 0 {
        return model.Pagination{}, fmt.Errorf("offset: %w", model.ErrInvalid)
    }
    return model.Pagination{
        Limit:      min(limit, maximumLimit),
        Offset:     offset,
        Sort:       ginContext.DefaultQuery("sort", "createdAt"),
        Descending: ginContext.DefaultQuery("order", "desc") == "desc",
    }, nil
}
```

### API-007 Reject unknown sort fields with 400

- **Severity:** must
- **Principle:** P6
- **Check:** a list endpoint that accepts any `sort` value. The allowlist itself is enforced in the repository ([DAT-011](data-access.md#dat-011-sort-only-by-allowlisted-keys)); the controller turns the resulting `model.ErrInvalid` into a 400.

When a new column becomes sortable, the query's `CASE` arms and the allowlist change in the same commit.

### API-008 Separate list and detail representations

- **Severity:** should
- **Principle:** P6
- **Check:** list endpoints returning full detail objects with nested relations.

```
GET /api/v1/users      -> ListResponse[UserListItem]   (flat, no relations)
GET /api/v1/users/:id  -> UserDetail                   (with relations)
```

### API-009 Follow REST conventions

- **Severity:** should
- **Principle:** P1
- **Check:** verbs or status codes that differ from the table without a documented reason; inconsistent route casing.

| Method | Route | Success |
|--------|-------|---------|
| GET | `/api/v1/<objects>` | 200 |
| GET | `/api/v1/<objects>/:id` | 200 / 404 |
| POST | `/api/v1/<objects>` | 201 |
| PUT | `/api/v1/<objects>/:id` | 200 / 404 |
| DELETE | `/api/v1/<objects>/:id` | 204 / 404 |

JSON field names are camelCase, set by struct tags on the model and payload types.

### API-010 Register the SPA handler last

- **Severity:** must
- **Principle:** P8
- **Check:** routes registered after `web.RegisterUI()`; the UI served from a `/*path` route; the UI answering unknown paths under the API base path with `index.html` instead of a 404 in the error shape (API-001); no test that requests an unknown API path and a deep frontend link.

`web.RegisterUI` installs the UI as engine middleware (`engine.Use`). Gin puts middleware into the chain of every route registered after it, so the UI answers those requests before their handlers run. A `/*path` catch-all route is no alternative: Gin panics when it conflicts with the API routes. The server mounts every controller first and the UI last, so a controller cannot get the order wrong:

```go
// Controller is implemented by every controller; the server mounts them under the API base path.
type Controller interface {
    RegisterRoutes(router gin.IRouter)
}

func (s *Server) registerRoutes() {
    apiRouter := s.engine.Group(s.options.APIBasePath)
    for _, controller := range s.options.Controllers {
        controller.RegisterRoutes(apiRouter)
    }
    web.RegisterUI(s.engine) // last
}
```

### API-011 Generate the client contract

- **Severity:** should
- **Principle:** P8
- **Check:** frontend types for API responses written by hand.

Either an OpenAPI spec with generated TypeScript types, or ConnectRPC with generated clients (keep plain REST for uploads, webhooks with raw-body signature checks, and health). `govengers/livewire` covers REST plus live subscriptions with a generated TypeScript client.

### API-012 Verify webhook signatures on the raw body

- **Severity:** must
- **Principle:** P6
- **Check:** a webhook endpoint that parses JSON before verifying the signature, or does not verify it at all.
