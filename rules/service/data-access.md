# Data access (`DAT`)

Profile: service. Stack: PostgreSQL, sqlc with pgx/v5, goose SQL migrations, squawk, `sqlc vet`. No ORM.

Why sqlc: queries are plain SQL checked against the schema at generate time (a hallucinated column fails with `file:line`), generation takes about a second, and the output is a few thousand lines of readable pgx code instead of 200k+ lines of framework code.

### DAT-001 All database access goes through the repository layer

- **Severity:** must
- **Principle:** P1, P3
- **Check:** a controller, service, middleware or job that uses the `pgxpool.Pool`, a `pgx.Tx` or the sqlc `Queries` directly.

One layer owns SQL, transactions, error mapping, caching and audit rows (ARC-001): one repository per business object, sharing the package's helpers (`inTransaction`, `mapError`). Everything above it calls repository methods.

### DAT-002 Queries are sqlc-generated from `.sql` files

- **Severity:** must
- **Principle:** P5, P8
- **Check:** SQL built with `fmt.Sprintf`, string concatenation or a query builder; `pool.Query`/`Exec` with inline SQL in Go code; an ORM in a new service.

Every query lives in `internal/repository/queries/*.sql` and is checked by `sqlc generate`. Optional filters use `sqlc.narg`, not a different query string.

```sql
-- name: ListUsers :many
SELECT sqlc.embed(users), count(*) OVER () AS total
FROM users
WHERE deleted_at IS NULL -- INT-005
  AND (sqlc.narg(search)::text IS NULL
       OR name ILIKE '%' || sqlc.narg(search) || '%'
       OR username ILIKE '%' || sqlc.narg(search) || '%')
  AND (sqlc.narg(active)::bool IS NULL OR active = sqlc.narg(active))
ORDER BY
    CASE WHEN @sort::text = 'name' AND NOT @descending::bool THEN name END ASC,
    CASE WHEN @sort::text = 'name' AND @descending::bool THEN name END DESC,
    CASE WHEN @sort::text = 'createdAt' AND NOT @descending::bool THEN created_at END ASC,
    CASE WHEN @sort::text = 'createdAt' AND @descending::bool THEN created_at END DESC,
    id
LIMIT @page_limit OFFSET @page_offset;
```

Do not mix named parameters (`@x`, `sqlc.narg`) and positional `$1` in one query; it is hard to read and easy to get wrong.

### DAT-003 Generated row types never leave the repository

- **Severity:** must
- **Principle:** P1, P8
- **Check:** sqlc output generated anywhere but `internal/repository/internal/sqlc`; repository methods returning `sqlc.*` types; handlers serializing row types; `emit_json_tags: true`.

Row types carry every column, including password hashes and TOTP secrets. With the output under `internal/repository/internal/`, the compiler rejects any import from outside the repository. Repository methods convert to `internal/model` types, which own the JSON contract.

```go
func toUser(row sqlc.User) *model.User {
    return &model.User{ID: row.ID, Username: row.Username, Email: row.Email, Role: model.Role(row.Role)}
}
```

### DAT-004 Map driver errors once, to sentinel errors

- **Severity:** must
- **Principle:** P4
- **Check:** `pgx.ErrNoRows` or `*pgconn.PgError` inspected outside the repository; repository methods returning raw driver errors for not-found, unique, check or FK violations.

```go
func mapError(err error) error {
    if errors.Is(err, pgx.ErrNoRows) {
        return model.ErrNotFound
    }
    var postgresError *pgconn.PgError
    if errors.As(err, &postgresError) {
        switch postgresError.Code {
        case "23505": // unique_violation
            return errors.Join(model.ErrConflict, err)
        case "23514", "23502", "22P02", "23503": // check, not null, invalid enum text, foreign key
            return errors.Join(model.ErrInvalid, err)
        }
    }
    return err
}
```

Without this, a duplicate username is a 500 instead of a 409.

### DAT-005 Schema changes are forward-only goose migrations

- **Severity:** must
- **Principle:** P5, P8
- **Check:** auto-migration from code; a migration file edited after it was merged; `-- +goose Down` sections; migrations run without an advisory lock; the server starting before `Migrate` returned.

Migrations are SQL files in `internal/database/migrations/`, embedded with `go:embed` and run by a goose provider with `lock.NewPostgresSessionLocker()` so replicas starting together do not migrate concurrently. A rollback is a new forward migration; down sections are code nobody runs.

### DAT-006 Migrations pass squawk and set lock timeouts

- **Severity:** must
- **Principle:** P6, P8
- **Check:** a migration flagged by squawk without a `-- squawk-ignore <rule>` line plus a reason; a migration without a lock timeout (`SET LOCAL lock_timeout`, or `SET lock_timeout` plus `RESET` in a `NO TRANSACTION` file); `CREATE INDEX` without `CONCURRENTLY` on an existing table; `CONCURRENTLY` in a file without `-- +goose NO TRANSACTION`.

```sql
-- +goose Up
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';
ALTER TABLE products ADD COLUMN archived_at timestamptz;
```

- `-- squawk-ignore` covers only the next line, so split multi-clause `ALTER TABLE`s.
- `SET LOCAL` only works inside a transaction. A `-- +goose NO TRANSACTION` file (needed for `CONCURRENTLY`) uses session-level `SET lock_timeout = '5s';` and ends with `RESET lock_timeout; RESET statement_timeout;`, so the pooled connection does not keep them. If the migration fails before the `RESET`, startup fails and the pool is closed with it (LAY-002).
- Large tables: `ADD CONSTRAINT ... NOT VALID` in one migration, `VALIDATE CONSTRAINT` in the next.
- Renames and drops break pods of the previous version during rollout. Add, migrate readers, drop later.

### DAT-007 Invariants live in the database

- **Severity:** must
- **Principle:** P5
- **Check:** a uniqueness, required-field, enum or range rule enforced only in Go; IDs or timestamps generated only in Go; `updated_at` maintained only by application code.

| Invariant | In the schema |
|-----------|---------------|
| required | `NOT NULL` |
| unique | unique index |
| closed set of values | `CREATE TYPE ... AS ENUM` (sqlc emits typed constants) or `CHECK (col IN (...))` |
| non-empty, length, range, format | `CHECK (col <> '')`, `CHECK (char_length(col) <= n)`, `CHECK (col BETWEEN a AND b)` |
| relation | foreign key with an explicit `ON DELETE` |
| id | `DEFAULT uuidv7()` or `DEFAULT uuidv4()` (Postgres 18), chosen per table |
| timestamps | `DEFAULT now()` plus a `set_updated_at()` `BEFORE UPDATE` trigger |

Keep validation at the API boundary for readable 400s; the constraint is the backstop no code path can skip.

Pick the UUID version per table:

| Version | Use for | Why |
|---------|---------|-----|
| `uuidv7()` | the default: tables that grow, are written often or are read in creation order (orders, events, audit logs, messages) | the leading millisecond timestamp makes inserts append at the right edge of the B-tree, so the index stays compact and hot in cache; random keys spread writes across every page |
| `uuidv4()` | IDs whose creation time must not leak to whoever sees them (users, accounts, anything that reveals growth or signup dates), and small tables where index locality does not matter | fully random, so the ID says nothing about when the row was made |

A large table whose ID is public and must not reveal its creation time gets a `uuidv7()` primary key plus a separate unique `uuidv4()` public ID; only the public ID leaves the service. Neither version is a secret: invite links, reset tokens and API keys use a random token from `crypto/rand`, never a row ID.

### DAT-008 Read-modify-write runs in one transaction with a row lock

- **Severity:** must
- **Principle:** P5
- **Check:** a mutation spanning several statements outside a transaction; a read followed by a dependent write without `FOR UPDATE`; transactions opened with `Begin` and rolled back manually on some paths only.

```go
// inTransaction runs operation in one transaction; returning an error rolls it back.
func inTransaction(ctx context.Context, pool *pgxpool.Pool, operation func(queries *sqlc.Queries) error) error {
    return pgx.BeginFunc(ctx, pool, func(transaction pgx.Tx) error {
        return operation(sqlc.New(transaction))
    })
}
```

Side effects outside the database (broadcasts, emails) run after commit, in the service (RT-001), never inside `operation`.

### DAT-009 Every list query is bounded

- **Severity:** must
- **Principle:** P6
- **Check:** a `:many` query without `LIMIT` that is not a lookup by `= ANY(@ids)`. The `no-unbounded-list` vet rule catches the plain form (DAT-018).

### DAT-010 No UPDATE or DELETE without WHERE

- **Severity:** must
- **Principle:** P5
- **Check:** an `UPDATE` or `DELETE FROM` statement without its own top-level `WHERE`, also inside a CTE (`WITH ... DELETE`) or with the only `WHERE` in a subquery. The `no-delete-without-where` vet rule catches the plain form (DAT-018).

### DAT-011 Sort only by allowlisted keys

- **Severity:** must
- **Principle:** P5, P6
- **Check:** a sort key from the request interpolated into SQL; a sort key passed to the query without checking it against the entity's allowlist first.

The `CASE` arms in DAT-002 silently fall back to `id` order on an unknown key. The repository checks the key against a per-entity allowlist that matches the query's `CASE` arms exactly and returns `model.ErrInvalid` before running the query. A global allowlist wider than one entity's arms lets unsupported keys through.

### DAT-012 Partial updates can also clear nullable columns

- **Severity:** should
- **Principle:** P5
- **Check:** an update query using only `COALESCE(sqlc.narg(x), x)` for a column the API allows to clear; the API then cannot set it to NULL.

```sql
-- name: UpdateUser :one
UPDATE users SET
    name = COALESCE(sqlc.narg(name), name),
    email = CASE WHEN @set_email::bool THEN sqlc.narg(email) ELSE email END,
    updated_by = @actor
WHERE id = @id
RETURNING *;
```

### DAT-013 Load relations in batches, not per row

- **Severity:** must
- **Principle:** P6
- **Check:** a query executed inside a loop over the results of another query.

Load the parents, then the children with `WHERE parent_id = ANY(@ids::uuid[])` and stitch them in Go: two queries instead of N+1. Use `sqlc.embed(other)` for N:1 joins.

### DAT-014 Know the upsert traps

- **Severity:** should
- **Principle:** P4
- **Check:** `ON CONFLICT DO NOTHING RETURNING ...` used with `:one`.

On conflict, `RETURNING` yields no row and `:one` returns `pgx.ErrNoRows`, which `mapError` turns into a misleading `ErrNotFound`. Use `ON CONFLICT (key) DO UPDATE SET col = EXCLUDED.col RETURNING *` or `:execrows`.

### DAT-015 PostgreSQL only, also in dev and tests

- **Severity:** must
- **Principle:** P9, P10
- **Check:** SQLite or another database supported alongside Postgres; Postgres-specific features avoided "for portability".

Dual database support taxes every query and hides prod bugs. Dev and tests use embedded-postgres (`fergusstrange/embedded-postgres`) or a Postgres container on the same major version as production.

### DAT-016 Run the check chain locally and in CI

- **Severity:** must
- **Principle:** P8
- **Check:** no justfile recipe running squawk, `sqlc generate`, `go build`, migrate-on-scratch-DB, `sqlc vet` and the repository tests; CI that does not fail on a diff in `internal/repository/internal/sqlc` after regeneration.

```just
# Offline, on every .sql edit.
db-lint:
    bunx squawk-cli@2.66.0 --pg-version 18 --assume-in-transaction internal/database/migrations/*.sql
    go tool sqlc generate
    go build ./...

# Needs Postgres: fresh scratch database, migrated by the app's own migrator.
db-check: db-lint
    psql "{{admin_url}}" -qc 'DROP DATABASE IF EXISTS sqlc_check' -c 'CREATE DATABASE sqlc_check'
    DATABASE_URL="{{check_url}}" go run ./cmd/migrate
    SQLC_DATABASE_URL="{{check_url}}" go tool sqlc vet
    go test ./internal/database/... ./internal/repository/...
```

After merging branches that add columns, re-run `sqlc generate` and diff: `go build` passes even when a query predates a new column.

### DAT-017 Tenant-scoped queries filter by tenant, checked by a test

- **Severity:** must
- **Principle:** P5, P8
- **Check:** in a multi-tenant service, a query on a tenant-scoped table without a `tenant_id` predicate and without a `-- tenant-exempt: <reason>` marker; no test enforcing this.

A regex vet rule cannot see which alias in a join lacks the predicate. Use a Go test that parses every query with `pg_query_go`, fails closed, and runs in `db-lint`.

### DAT-018 Standard sqlc configuration

- **Severity:** should
- **Principle:** P8
- **Check:** `sqlc.yaml` without `sql_package: pgx/v5`, without the uuid override, with `emit_json_tags`, or without the vet rules.

```yaml
version: "2"
sql:
  - engine: postgresql
    schema: internal/database/migrations
    queries: internal/repository/queries
    database:
      uri: ${SQLC_DATABASE_URL}
    analyzer:
      database: false
    rules: [sqlc/db-prepare, no-unbounded-list, no-delete-without-where]
    gen:
      go:
        package: sqlc
        out: internal/repository/internal/sqlc
        sql_package: pgx/v5
        emit_pointers_for_null_types: true
        emit_enum_valid_method: true
        emit_all_enum_values: true
        emit_empty_slices: true
        overrides:
          - db_type: uuid
            go_type: github.com/google/uuid.UUID
          - db_type: uuid
            nullable: true
            go_type: {import: github.com/google/uuid, type: UUID, pointer: true}
          - db_type: timestamptz
            go_type: time.Time
          - db_type: timestamptz
            nullable: true
            go_type: {type: time.Time, pointer: true}
rules:
  - name: no-unbounded-list
    message: ":many query without LIMIT - paginate or bound it"
    rule: query.cmd == "many" && !query.sql.matches("(?i)\\bLIMIT\\b") && !query.sql.matches("(?i)= ANY\\(")
  - name: no-delete-without-where
    message: "DELETE or UPDATE without WHERE"
    rule: query.sql.matches("(?i)^\\s*(DELETE\\s+FROM|UPDATE)\\s") && !query.sql.matches("(?i)\\bWHERE\\b")
```

- With `sql_package: pgx/v5` the timestamptz override uses the bare `timestamptz`; `pg_catalog.timestamptz` silently does nothing and fields stay `pgtype.Timestamptz`.
- In CEL rules `query.cmd` is `"many"`, not `":many"`. A rule written with the colon never fires.
- The two vet rules are regex guards and cheap, not proof: they miss a mutation wrapped in a CTE (`WITH ... DELETE`) and accept an `UPDATE` whose only `WHERE` sits in a subquery. DAT-009 and DAT-010 are graded on the query text, so the reviewer catches those forms; a repo that wants the machine to catch them parses the queries with `pg_query_go` in a test, as DAT-017 does.
- `analyzer.database: false` keeps `generate` offline; `database.uri` serves only `sqlc vet` and must point at a migrated database.

### DAT-019 Caching lives in the repository and is invalidated on mutation

- **Severity:** should
- **Principle:** P1, P5
- **Check:** caches in handlers or services; a cached entity whose update or delete path does not invalidate the cache entry.

Use `govengers/cache`: `LocalCache` for a single replica, `SynchronizedCache` (local + Redis with pub/sub invalidation) for several.

### DAT-020 Size the connection pool explicitly

- **Severity:** should
- **Principle:** P6
- **Check:** a `pgxpool` created without `MaxConns` (in code or as `pool_max_conns` in the URL); `MaxConns` times the maximum replica count above the database's `max_connections` minus a reserve for migrations and admin sessions.

pgxpool defaults to `max(4, runtime.NumCPU())`, and `NumCPU` in a container is the node's core count, not the CPU limit. Ten replicas on 64-core nodes then try to open 640 connections and Postgres answers "too many clients already" during a scale-up.

```go
func NewPool(ctx context.Context, options *Options) (*pgxpool.Pool, error) {
    poolConfiguration, err := pgxpool.ParseConfig(options.URL)
    if err != nil {
        return nil, err
    }
    poolConfiguration.MaxConns = options.MaximumConnections // sized against max_connections / replicas
    poolConfiguration.MaxConnLifetime = 30 * time.Minute
    poolConfiguration.MaxConnIdleTime = 5 * time.Minute
    return pgxpool.NewWithConfig(ctx, poolConfiguration)
}
```
