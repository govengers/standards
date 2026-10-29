# Real-time (`RT`)

Profile: service

### RT-001 Every mutation broadcasts an event after commit

- **Severity:** must
- **Principle:** P7
- **Check:** a service mutation (create, update, delete) that does not broadcast after the repository call returned; a broadcast from a repository or controller; a broadcast sent before the transaction committed.

Clients update without polling. The service broadcasts once the repository method has returned, which is after commit; broadcasting earlier announces changes that may roll back. The repository stays persistence-only (ARC-001). The service reaches the WebSocket hub through an interface it declares (ARC-002), and `Broadcast` never blocks the request: the hub queues the message and its own goroutine filters and delivers it (CON-005, CON-006).

```go
// in package service, implemented by *event.Hub
type Broadcaster interface {
    Broadcast(object event.Object, action event.Action, data any, filter event.BroadcastFilter)
}

func (s *ProductService) Create(ctx context.Context, input CreateProductInput) (*model.Product, error) {
    product, err := s.options.ProductRepository.Create(ctx, toCreateProductParameters(input))
    if err != nil {
        return nil, err
    }
    s.options.Broadcaster.Broadcast(event.ObjectProduct, event.ActionCreate, product, authorization.ProductBroadcastFilter(product))
    return product, nil
}
```

### RT-002 Typed event objects and actions

- **Severity:** must
- **Principle:** P8
- **Check:** event objects or actions as string literals at the call site.

```go
type Object string
type Action string

const (
    ObjectPing    Object = "ping"
    ObjectUser    Object = "user"
    ObjectProduct Object = "product" // one constant per business object
)

const (
    ActionCreate Action = "create"
    ActionUpdate Action = "update"
    ActionDelete Action = "delete"
)

type Message[T any] struct {
    Object Object `json:"object"`
    Action Action `json:"action"`
    Data   T      `json:"data"`
}
```

### RT-003 Broadcasts are filtered by the same authorization rules as HTTP

- **Severity:** must
- **Principle:** P6
- **Check:** an unfiltered broadcast of data that the HTTP API restricts; broadcast filters that reimplement permission logic instead of calling the shared `CanViewX` function.

```go
func CanViewUser(viewer, target *model.User) bool {
    if viewer == nil || !viewer.Active {
        return false
    }
    return viewer.Role == model.RoleAdmin || (target != nil && viewer.ID == target.ID)
}

func UserBroadcastFilter(target *model.User) event.BroadcastFilter {
    return func(viewer *model.User) bool { return CanViewUser(viewer, target) }
}
```

### RT-004 Check the viewer's current permissions at broadcast time

- **Severity:** must
- **Principle:** P6
- **Check:** the user object captured at connection time and used for filtering for the life of the connection.

Look the viewer up through a `UserProvider` interface on each broadcast, so a revoked role stops the stream immediately. The interface is declared in `event` and implemented by the cached user repository: the lookup is a plain read, and routing it through the user service would build a cycle, because the user service broadcasts through the hub (ARC-002).

### RT-005 Detect dead connections with a heartbeat

- **Severity:** should
- **Principle:** P6
- **Check:** no ping/heartbeat, no write deadline, or dead connections never removed from the hub.

Ping every ~10 s from a `time.Ticker` owned by the hub (CON-006), set a write deadline per message, drop the connection on failure.

### RT-006 Keep mutation broadcasts and session streams apart

- **Severity:** should
- **Principle:** P1, P6
- **Check:** per-session data (chat streams, job progress for one user) sent through the mutation broadcast channel, or mutation events sent through a session stream without authorization filtering.

| Channel | Audience | Filter |
|---------|----------|--------|
| mutation broadcast | everyone allowed to see the entity | authorization filter |
| session stream | one session | session ID |

Key session streams by the same ID the client subscribes with (usually the public UUID, not the database primary key). A mismatch drops frames silently.
