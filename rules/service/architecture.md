# Architecture (`ARC`)

Profile: service. How a service is cut into layers. A library with a transport applies the same split inside its own packages (LIB-007).

```
          controller          transport: REST, WebSocket, GraphQL, RPC
              |
           service            business logic
            /    \
   repository    client       persistence (database, cache) | one external system each

   model                      domain types and domain errors, imported by every layer
```

### ARC-001 Split a service into controller, service, repository and client layers

- **Severity:** must
- **Principle:** P1, P3
- **Check:** business rules (calculations, state transitions, ownership checks, orchestration of several writes) in a controller or repository; SQL, transactions or cache access outside a repository; calls to another system outside a client package; transport types (`*gin.Context`, `*http.Request`, resolver arguments, WebSocket frames) in a service or repository.

| Layer | Package | Does | Never |
|-------|---------|------|-------|
| controller | `internal/controller` | decodes and checks the request shape, applies static role gates (AUTH-005), calls one service method, encodes the result or the error | business rules, SQL, calls to repositories or clients |
| service | `internal/service` | business rules, data-dependent authorization, orchestration of repositories and clients, broadcasts after a mutation (RT-001) | transport types, status codes, SQL, cache access |
| repository | `internal/repository` | SQL, transactions, audit rows (INT-001), caching (DAT-019), driver error mapping (DAT-004) | business decisions, broadcasts, calls to clients |
| client | `internal/client/<system>` | one external system: protocol, authentication, timeouts, retries (RES), error mapping | business decisions, database access |

Each business object gets one controller, one service and one repository (`ProductController`, `ProductService`, `ProductRepository`); a service may use several repositories and clients. A business operation that must be atomic across tables is one repository method running one transaction: the service decides what to write, the repository decides how to write it atomically.

### ARC-002 Dependencies point down; no layer is skipped

- **Severity:** must
- **Principle:** P3, P8
- **Check:** `internal/controller` importing `internal/repository` or `internal/client/...`; `internal/service` importing `internal/controller` or `github.com/gin-gonic/gin`; `internal/repository` or a client importing `internal/service` or `internal/controller`; `internal/model` importing any other internal package.

A controller that reads straight from the repository works until the endpoint needs an ownership check or a broadcast; then the check lands in the controller or is forgotten. Every controller calls a service method, even one that only forwards to the repository today. That is not the forwarding layer DES-005 warns about: it is where the rule goes the day it appears, without touching the controller.

When a lower layer has to reach up (a service broadcasts through the WebSocket hub), it declares a small interface (DES-004) and `main` passes the implementation in. Two kinds of infrastructure read straight from a repository through an interface they declare, because going through a service would build a cycle or add nothing: the WebSocket hub looking up a viewer (RT-004) and an adapter that implements a library's storage interface (the auth library's user storage). Such adapters live in `internal/repository`.

```go
// bad: the controller reaches into the repository
type ProductControllerOptions struct {
    ProductRepository *repository.ProductRepository
}

// good
type ProductControllerOptions struct {
    ProductService *service.ProductService
}
```

### ARC-003 Services are transport-agnostic

- **Severity:** must
- **Principle:** P3, P9
- **Check:** a service method taking `*gin.Context`, `*http.Request`, `http.ResponseWriter`, a controller payload type or a WebSocket frame; a service returning status codes, `ErrorResponse` or a response type shaped for one transport; the acting user passed as a parameter instead of read from the context.

A service method takes the context and a typed input and returns model types and `model` sentinel errors (ERR-005). The acting user comes from the context (AUTH-006); the controller maps errors to status codes (API-002). REST, WebSocket, a job and a test then call the same method the same way.

```go
// bad
func (s *ProductService) Create(ginContext *gin.Context)

// good
func (s *ProductService) Create(ctx context.Context, input CreateProductInput) (*model.Product, error)
```

### ARC-004 Each layer owns the types of its API

- **Severity:** should
- **Principle:** P1, P8
- **Check:** a service method taking a controller payload type; a repository method taking a service input type; sqlc parameter or row types outside the repository (DAT-003); JSON or binding tags on service input types.

| Layer | Input type | Carries |
|-------|-----------|---------|
| controller | `CreateProductPayload` | wire format: JSON and binding tags (API-004) |
| service | `CreateProductInput` | business fields, no tags |
| repository | `CreateProductParameters` | what is written |

Every layer returns `model` types. Map between input types with a plain function next to the caller (`toCreateProductInput(payload)`), so a change to the wire format never reaches the database code.

### ARC-005 Reach every external system through its own client package

- **Severity:** should
- **Principle:** P1, P9
- **Check:** outbound HTTP or SDK calls (payment provider, LLM provider, SMTP, object storage) outside `internal/client/<system>`; a client package that makes business decisions; a service whose tests can only run against the real external system.

One package per system (`internal/client/openrouter`, `internal/client/postmark`), built with options (base URL, credentials, timeout) in `main`. The client speaks the protocol, maps provider errors to its own sentinels (LIB-010) and is tested against `httptest.NewServer` (TST-006). The service declares the narrow interface it consumes, so its tests pass a fake.

```go
// in package service
type CompletionProvider interface {
    Complete(ctx context.Context, request openrouter.CompletionRequest) (*openrouter.Completion, error)
}

type SummaryServiceOptions struct {
    CompletionProvider CompletionProvider // *openrouter.Client in main, a fake in tests
    DocumentRepository *repository.DocumentRepository
}
```

### ARC-006 Wire components in `main`, nowhere else

- **Severity:** must
- **Principle:** P3, P9
- **Check:** a component constructor that calls another component's constructor (`NewUserService` calling `repository.NewUserRepository`); a component that finds a collaborator through a global, a registry or a service locator; a component that reads configuration (CFG-006).

`main` builds every repository, client, service and controller with `New...(options)` in dependency order (LAY-002) and hands each one the collaborators it needs. Components never build their own, so a test builds the same component with different ones. Components are the application's own controllers, services, repositories, clients, hubs and servers; building library or generated helpers from injected values inside a constructor (`sqlc.New(pool)`, `&http.Client{Timeout: options.Timeout}`) is fine.

```go
// bad: the service builds its own repository from a global pool
func NewUserService() *UserService {
    return &UserService{userRepository: repository.NewUserRepository(&repository.UserRepositoryOptions{Pool: database.Pool})}
}

// good: main passes it in
userService, err := service.NewUserService(&service.UserServiceOptions{UserRepository: userRepository})
```
