# Functions (`FUN`)

Profile: core

### FUN-001 A function does one thing

- **Severity:** must
- **Principle:** P1
- **Check:** a function whose honest name needs "and" (`validateAndSave`, `parseAndRespond`); a boolean or mode parameter that selects between two behaviors (`save(user, true)`); a function that does the work of more than one layer (a handler that computes business values, a service method that formats an HTTP response).

One thing means one reason to change. If the true name needs "and", split it. Orchestration is one thing: a service method that validates, computes, stores and broadcasts in sequence does one thing (placing an order), as long as each step is a call (FUN-003).

```go
// bad: the flag picks one of two functions
func (s *UserService) Save(ctx context.Context, user *model.User, isNew bool) error

// good
func (s *UserService) Create(ctx context.Context, input CreateUserInput) (*model.User, error)
func (s *UserService) Update(ctx context.Context, id uuid.UUID, input UpdateUserInput) (*model.User, error)
```

### FUN-002 No side effect the name does not announce

- **Severity:** must
- **Principle:** P1, P3
- **Check:** a function named like a question or a conversion (`get`, `find`, `is`, `has`, `can`, `parse`, `validate`, `check`, `to`, `build`, `compute`, `format`) that also changes state: writes or aborts an HTTP response, writes to a database, sends a message, mutates an argument or its receiver, writes a package-level variable, starts a goroutine or writes a standalone log line; a constructor that modifies the options it received.

A reader must be able to predict everything a call changes from its name and signature. Questions answer, commands change. A function that has to do both names the change (`ClaimJobs`, `ConsumeBackupCode`, `RefreshSubscription`). Two writes are not observable state changes and are allowed in any function: recording on the context's wide event (LOG-004), and filling a read-through cache (DAT-019).

```go
// bad: a parser that also writes the 400 response
func idParameter(ginContext *gin.Context) (uuid.UUID, bool) {
    id, err := uuid.Parse(ginContext.Param("id"))
    if err != nil {
        ginContext.AbortWithStatusJSON(http.StatusBadRequest, ErrorResponse{Code: "invalid_argument", Message: "invalid id"})
        return uuid.Nil, false
    }
    return id, true
}

// good: it parses; the handler decides what a failure means
func idParameter(ginContext *gin.Context) (uuid.UUID, error) {
    id, err := uuid.Parse(ginContext.Param("id"))
    if err != nil {
        return uuid.Nil, fmt.Errorf("id %q: %w", ginContext.Param("id"), model.ErrInvalid)
    }
    return id, nil
}
```

```go
// bad: validating the input silently rewrites the caller's struct
func validateSignup(input *SignupInput) error {
    input.Email = strings.ToLower(strings.TrimSpace(input.Email))
    ...
}

// good: the conversion returns a new value
func normalizeEmail(email string) string {
    return strings.ToLower(strings.TrimSpace(email))
}
```

### FUN-003 Keep one level of abstraction per function

- **Severity:** must
- **Principle:** P1
- **Check:** a function body that mixes calls to named steps with the mechanics of a lower level: loops over raw data, string or byte manipulation, arithmetic on fields, map lookups with fallbacks, SQL or HTTP plumbing, placed between lines that read as steps of the task.

Every statement in a function sits at the same height. The top-level function tells the whole story; a reader goes one call deeper only for the step they care about. When a step needs detail, the detail becomes a function named after the step.

```go
// bad: the steps of placing an order are buried in lookups and arithmetic
func (s *OrderService) PlaceOrder(ctx context.Context, input PlaceOrderInput) (*model.Order, error) {
    products, err := s.options.ProductRepository.GetMany(ctx, input.ProductIDs())
    if err != nil {
        return nil, fmt.Errorf("place order: %w", err)
    }
    var totalCents int64
    for _, line := range input.Lines {
        product, found := products[line.ProductID]
        if !found || !product.Active {
            return nil, fmt.Errorf("product %s: %w", line.ProductID, model.ErrInvalid)
        }
        totalCents += product.PriceCents * int64(line.Quantity)
    }
    if totalCents > s.options.MaximumOrderCents {
        return nil, fmt.Errorf("order total %d cents: %w", totalCents, model.ErrInvalid)
    }
    // ... create, broadcast
}

// good: every line is one step of placing an order
func (s *OrderService) PlaceOrder(ctx context.Context, input PlaceOrderInput) (*model.Order, error) {
    products, err := s.options.ProductRepository.GetMany(ctx, input.ProductIDs())
    if err != nil {
        return nil, fmt.Errorf("place order: %w", err)
    }
    totalCents, err := orderTotalCents(input.Lines, products, s.options.MaximumOrderCents)
    if err != nil {
        return nil, err
    }
    order, err := s.options.OrderRepository.Create(ctx, toCreateOrderParameters(input, totalCents))
    if err != nil {
        return nil, err
    }
    s.options.Broadcaster.Broadcast(event.ObjectOrder, event.ActionCreate, order, authorization.OrderBroadcastFilter(order))
    return order, nil
}
```

### FUN-004 Keep functions short and flat

- **Severity:** should
- **Principle:** P1, P8
- **Check:** enforced by `funlen` (60 lines, 40 statements), `nestif`, `gocognit` and revive's `argument-limit` (five, `ctx` included) and `function-result-limit` (three) in [.golangci.yml](../../.golangci.yml).

Length, nesting and long parameter lists are symptoms of a function that does several things (FUN-001) or mixes levels (FUN-003). Return early instead of nesting. Group many parameters of an operation into a named struct (`CreateProductParameters`); constructors take an options struct (DES-001).

```go
// bad
if user != nil {
    if user.Active {
        if user.Role == model.RoleAdmin {
            return true
        }
    }
}
return false

// good
if user == nil || !user.Active {
    return false
}
return user.Role == model.RoleAdmin
```

### FUN-005 Keep business decisions in pure functions

- **Severity:** should
- **Principle:** P1, P9
- **Check:** a calculation, validation, state transition or permission decision computed inline between I/O calls, so that it can only be tested through a database, an HTTP server or a fake.

Decide in pure functions, act in the method around them. `orderTotalCents(lines, products, maximum)` takes values and returns values, so a table test covers every edge case in microseconds, and the service method that loads, decides and stores needs only a few tests for its wiring (TST-012).

```go
func TestOrderTotalCents(t *testing.T) {
    desk := &model.Product{ID: uuid.New(), PriceCents: 24900, Active: true}
    products := map[uuid.UUID]*model.Product{desk.ID: desk}

    testCases := []struct {
        name      string
        lines     []model.OrderLine
        want      int64
        wantError error
    }{
        {name: "multiplies price by quantity", lines: []model.OrderLine{{ProductID: desk.ID, Quantity: 2}}, want: 49800},
        {name: "rejects an unknown product", lines: []model.OrderLine{{ProductID: uuid.New(), Quantity: 1}}, wantError: model.ErrInvalid},
        {name: "rejects a total above the maximum", lines: []model.OrderLine{{ProductID: desk.ID, Quantity: 5}}, wantError: model.ErrInvalid},
    }
    for _, testCase := range testCases {
        t.Run(testCase.name, func(t *testing.T) {
            got, err := orderTotalCents(testCase.lines, products, 100000)
            require.ErrorIs(t, err, testCase.wantError)
            require.Equal(t, testCase.want, got)
        })
    }
}
```

### FUN-006 Name non-trivial conditions, and state them positively

- **Severity:** should
- **Principle:** P1
- **Check:** a condition with more than two clauses, or with a clause whose meaning takes thought (time arithmetic, bit masks, `!(a || !b)`), that is not a named variable or predicate function; negated names that force double negation (`notFound`, `isNotValid`, `if !disableCache`).

A named condition is the alternative to a comment above the `if` (CMT-001). The predicate is also a pure decision that a table test covers (FUN-005). Name booleans for the positive case and negate at the call site.

```go
// bad
if user.Active && !user.Locked && (user.ExpiresAt.IsZero() || user.ExpiresAt.After(now)) {
    ...
}
if !notFound { ... }

// good
if user.CanSignIn(now) {
    ...
}
if found { ... }

func (u *User) CanSignIn(now time.Time) bool {
    stillValid := u.ExpiresAt.IsZero() || u.ExpiresAt.After(now)
    return u.Active && !u.Locked && stillValid
}
```

### FUN-007 Order a file top-down

- **Severity:** should
- **Principle:** P1
- **Check:** a helper declared above the functions that call it, so the file reads details before the story; a type's constructor and methods split up by unrelated declarations.

A file reads like a newspaper: the exported entry points first, the helpers they call below them, in the order they are called. Per type: the type, its options, its constructor, its methods, then the unexported helpers. A reader stops reading once they know enough.
