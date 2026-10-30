# Playbook: add a business object

Guidance, not graded. From migration to API endpoint for a new entity (`product`) in a service on the standard stack. Rules referenced in brackets.

```
1. Migration -> 2. Queries -> 3. Model -> 4. Repository -> 5. Service -> 6. Controller -> 7. Wiring in main -> 8. Tests
```

Every layer is a struct built with an options struct (DES-001) and wired in `main` (ARC-006). Dependencies point down: controller -> service -> repository (ARC-002).

## 1. Migration

`internal/database/migrations/00007_products.sql` (next free goose number):

```sql
-- +goose Up
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

CREATE TYPE product_status AS ENUM ('draft', 'published', 'archived');

CREATE TABLE products (
    id          uuid PRIMARY KEY DEFAULT uuidv7(),
    name        text NOT NULL CHECK (name <> ''),
    description text,
    price_cents bigint NOT NULL CHECK (price_cents >= 0),
    status      product_status NOT NULL DEFAULT 'draft',
    active      boolean NOT NULL DEFAULT true,
    category_id uuid REFERENCES categories (id) ON DELETE SET NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    created_by  uuid NOT NULL,
    updated_by  uuid NOT NULL
);

CREATE UNIQUE INDEX products_name_key ON products (name);
CREATE TRIGGER products_set_updated_at BEFORE UPDATE ON products
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
```

Invariants as constraints [DAT-007], timeouts first [DAT-006], forward only [DAT-005]. Money as integer cents, never float. Indexes on a new, empty table need no `CONCURRENTLY`.

## 2. Queries

`internal/repository/queries/products.sql`:

```sql
-- name: GetProduct :one
SELECT * FROM products WHERE id = @id;

-- name: LockProduct :one
SELECT * FROM products WHERE id = @id FOR UPDATE;

-- name: ListProducts :many
SELECT sqlc.embed(products), count(*) OVER () AS total
FROM products
WHERE (sqlc.narg(search)::text IS NULL
       OR name ILIKE '%' || sqlc.narg(search) || '%'
       OR description ILIKE '%' || sqlc.narg(search) || '%')
  AND active = COALESCE(sqlc.narg(active)::bool, true)
ORDER BY
    CASE WHEN @sort::text = 'name' AND NOT @descending::bool THEN name END ASC,
    CASE WHEN @sort::text = 'name' AND @descending::bool THEN name END DESC,
    CASE WHEN @sort::text = 'createdAt' AND NOT @descending::bool THEN created_at END ASC,
    CASE WHEN @sort::text = 'createdAt' AND @descending::bool THEN created_at END DESC,
    id
LIMIT @page_limit OFFSET @page_offset;

-- name: CreateProduct :one
INSERT INTO products (id, name, description, price_cents, created_by, updated_by)
VALUES (COALESCE(sqlc.narg(id)::uuid, uuidv7()), @name, sqlc.narg(description), @price_cents, @actor, @actor)
RETURNING *;

-- name: UpdateProduct :one
UPDATE products SET
    name = COALESCE(sqlc.narg(name), name),
    description = CASE WHEN @set_description::bool THEN sqlc.narg(description) ELSE description END,
    price_cents = COALESCE(sqlc.narg(price_cents), price_cents),
    updated_by = @actor
WHERE id = @id
RETURNING *;

-- name: DeleteProduct :execrows
DELETE FROM products WHERE id = @id;
```

- Active-only by default, `?active=false` for inactive ones.
- The optional `id` on create lets bulk imports keep their UUIDs; clients that omit it get a generated one.
- Run `just db-lint`: squawk, `sqlc generate`, `go build` [DAT-016].

## 3. Model

`internal/model/product.go` owns the JSON contract [DAT-003]; `internal/model/errors.go` holds the shared sentinel errors [ERR-005]:

```go
type Product struct {
    ID          uuid.UUID     `json:"id"`
    Name        string        `json:"name"`
    Description *string       `json:"description,omitempty"`
    PriceCents  int64         `json:"priceCents"`
    Status      ProductStatus `json:"status"`
    Active      bool          `json:"active"`
    CreatedAt   time.Time     `json:"createdAt"`
    UpdatedAt   time.Time     `json:"updatedAt"`
}
```

## 4. Repository

`internal/repository/product.go`: persistence only [ARC-001].

| Operation | Signature |
|-----------|-----------|
| get | `Get(ctx, id uuid.UUID) (*model.Product, error)` |
| list | `List(ctx, parameters ListProductsParameters) ([]*model.Product, int, error)` |
| create | `Create(ctx, parameters CreateProductParameters) (*model.Product, error)` |
| update | `Update(ctx, id uuid.UUID, parameters UpdateProductParameters) (*model.Product, bool, error)` (the bool says whether anything changed) |
| delete | `Delete(ctx, id uuid.UUID) error` |

Every mutation has the same shape: transaction, lock, write, audit row in the same transaction, commit [DAT-008, INT-001]. No broadcast here; that is the service's job [RT-001].

```go
type ProductRepositoryOptions struct {
    Pool *pgxpool.Pool
}

type ProductRepository struct {
    options ProductRepositoryOptions
    queries *sqlc.Queries
}

func NewProductRepository(options *ProductRepositoryOptions) (*ProductRepository, error) {
    if options == nil || options.Pool == nil {
        return nil, errors.New("product repository: Pool is required")
    }
    return &ProductRepository{options: *options, queries: sqlc.New(options.Pool)}, nil
}

var productSortFields = []string{"name", "createdAt"} // matches the CASE arms in ListProducts [DAT-011]

func (r *ProductRepository) Update(ctx context.Context, id uuid.UUID, parameters UpdateProductParameters) (*model.Product, bool, error) {
    var before, updated sqlc.Product
    err := inTransaction(ctx, r.options.Pool, func(queries *sqlc.Queries) error {
        var err error
        before, err = queries.LockProduct(ctx, id)
        if err != nil {
            return mapError(err)
        }
        updated, err = queries.UpdateProduct(ctx, sqlc.UpdateProductParams{
            ID: id, Actor: actor.ID(ctx), Name: parameters.Name, PriceCents: parameters.PriceCents,
            SetDescription: parameters.SetDescription, Description: parameters.Description,
        })
        if err != nil {
            return mapError(err)
        }
        changes := productChanges(before, updated)
        if len(changes) == 0 {
            return errNoChange // rolls back the UPDATE and its trigger-set updated_at
        }
        return queries.InsertAuditLog(ctx, auditUpdate(ctx, "product", id, changes))
    })
    if errors.Is(err, errNoChange) {
        return toProduct(before), false, nil // the committed state, not the rolled-back row
    }
    if err != nil {
        return nil, false, fmt.Errorf("update product %s: %w", id, err)
    }
    return toProduct(updated), true, nil
}
```

`Delete` returns `model.ErrNotFound` when `:execrows` reports 0 rows.

## 5. Service

`internal/service/product.go`: business rules, data-dependent authorization, broadcasts [ARC-001, AUTH-005, RT-001]. Transport-agnostic: context and typed input in, model types and `model` errors out [ARC-003]. Add `ObjectProduct Object = "product"` to `internal/event/events.go` [RT-002].

```go
type CreateProductInput struct {
    Name        string
    Description *string
    PriceCents  int64
}

type ProductServiceOptions struct {
    ProductRepository *repository.ProductRepository
    Broadcaster       Broadcaster // *event.Hub in main, a recording fake in tests
    MaximumPriceCents int64
}

type ProductService struct {
    options ProductServiceOptions
}

func (s *ProductService) Create(ctx context.Context, input CreateProductInput) (*model.Product, error) {
    if err := checkPrice(input.PriceCents, s.options.MaximumPriceCents); err != nil {
        return nil, err
    }
    product, err := s.options.ProductRepository.Create(ctx, toCreateProductParameters(input))
    if err != nil {
        return nil, err
    }
    recordProductAction(ctx, "product.create", product.ID)
    s.options.Broadcaster.Broadcast(event.ObjectProduct, event.ActionCreate, product, authorization.ProductBroadcastFilter(product))
    return product, nil
}

// checkPrice is the business rule as a pure function [FUN-005].
func checkPrice(priceCents, maximumPriceCents int64) error {
    if priceCents > maximumPriceCents {
        return fmt.Errorf("price %d cents above the maximum of %d: %w", priceCents, maximumPriceCents, model.ErrInvalid)
    }
    return nil
}

// recordProductAction adds the business action to the request's wide event [LOG-003].
func recordProductAction(ctx context.Context, action string, productID uuid.UUID) {
    wideevent.FromContext(ctx).String("action", action).UUID("product.id", productID)
}
```

`Update` broadcasts only when the repository reports a change [INT-003]. The constructor validates `ProductRepository` and `Broadcaster` and defaults `MaximumPriceCents` on its copy [DES-001].

## 6. Controller

`internal/controller/product.go`: payload types [API-004], thin handlers [API-003], static role gates [AUTH-005], one error mapper [API-002].

```go
type CreateProductPayload struct {
    Name        string  `json:"name" binding:"required"`
    Description *string `json:"description,omitempty"`
    PriceCents  int64   `json:"priceCents" binding:"gte=0"`
}

type ProductControllerOptions struct {
    ProductService *service.ProductService
}

func (c *ProductController) RegisterRoutes(router gin.IRouter) {
    router.GET("/products", c.listProductsHandler())
    router.GET("/products/:id", c.getProductHandler())
    router.POST("/products", c.createProductHandler())
    router.PUT("/products/:id", c.updateProductHandler())
    router.DELETE("/products/:id", c.deleteProductHandler())
}

func (c *ProductController) createProductHandler() gin.HandlerFunc {
    return func(ginContext *gin.Context) {
        ctx := ginContext.Request.Context()
        if !authorization.IsAdmin().Check(ctx) {
            respondError(ginContext, model.ErrPermissionDenied)
            return
        }
        var payload CreateProductPayload
        if err := ginContext.ShouldBindJSON(&payload); err != nil {
            respondError(ginContext, fmt.Errorf("create product payload: %w", errors.Join(model.ErrInvalid, err)))
            return
        }
        product, err := c.options.ProductService.Create(ctx, toCreateProductInput(payload))
        if err != nil {
            respondError(ginContext, err) // records we.Failure(err) [LOG-002]
            return
        }
        respond(ginContext, http.StatusCreated, product) // records we.Success() [LOG-011]
    }
}

func toCreateProductInput(payload CreateProductPayload) service.CreateProductInput {
    return service.CreateProductInput{Name: payload.Name, Description: payload.Description, PriceCents: payload.PriceCents}
}
```

## 7. Wiring in main

`cmd/server/main.go` builds the three components in order and copies configuration values into their options [LAY-002, CFG-006]:

```go
productRepository, err := repository.NewProductRepository(&repository.ProductRepositoryOptions{Pool: pool})
if err != nil {
    return err
}
productService, err := service.NewProductService(&service.ProductServiceOptions{
    ProductRepository: productRepository,
    Broadcaster:       eventHub,
    MaximumPriceCents: int64(configuration.ProductMaximumPriceCents), // bound by config.Int("PRODUCT_MAXIMUM_PRICE_CENTS").Into(...) [CFG-001]
})
if err != nil {
    return err
}
productController, err := controller.NewProductController(&controller.ProductControllerOptions{ProductService: productService})
if err != nil {
    return err
}
controllers = append(controllers, productController) // the server mounts them before the UI [API-010]
```

## 8. Tests

Where each layer's bugs live [TST-012]:

- **Pure rules:** table test for `checkPrice` and `productChanges` [FUN-005, TST-007].
- **Repository** against a real Postgres per test [TST-002]: create, duplicate name gives `model.ErrConflict`, negative price gives `model.ErrInvalid`, unknown sort key gives `model.ErrInvalid`, update writes an audit row, no-op update writes none and reports no change.
- **Service** with the real repository and a recording `Broadcaster` fake: create broadcasts once, no-op update broadcasts nothing, a price above the maximum is rejected before any write.
- **Authorization:** admin allowed, user denied, inactive admin denied [TST-003].
- **Controller** with `httptest.NewRecorder` through the router: 201, 400, 403, 404, 409.
- **End to end** against the built binary: create, get, list, update, delete, and a 403 for a non-admin [TST-011].

## Checklist

- [ ] Migration with constraints, timeouts, trigger; squawk clean
- [ ] Queries in `queries/products.sql`; `just db-check` green
- [ ] Model type with JSON tags; row types stay in the repository
- [ ] Repository: options struct, sort allowlist, mutations in `inTransaction` with audit, no broadcast
- [ ] Service: options struct, business rules as pure functions, broadcast after the repository returned, action on the wide event
- [ ] Controller: options struct, payload types, thin handlers, routes via `RegisterRoutes`
- [ ] Wired in `main`, configuration copied into options, nothing reads configuration elsewhere
- [ ] Tests per layer plus the end-to-end flow; `just check` green
