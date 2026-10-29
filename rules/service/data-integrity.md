# Data integrity (`INT`)

Profile: service

### INT-001 Audit every mutation in the same transaction

- **Severity:** must
- **Principle:** P5, P7
- **Check:** a create, update or delete without an audit log entry; an audit entry written in a separate goroutine or after commit, where a crash loses it.

Writing the audit row inside the mutation's transaction makes it atomic: either the change and its record both exist, or neither does. With sqlc this is one more query in `inTransaction`.

```go
err := inTransaction(ctx, r.options.Pool, func(queries *sqlc.Queries) error {
    before, err := queries.LockProduct(ctx, id)
    if err != nil {
        return mapError(err)
    }
    after, err := queries.UpdateProduct(ctx, updateArguments)
    if err != nil {
        return mapError(err)
    }
    changes := productChanges(before, after)
    if len(changes) == 0 {
        return errNoChange // rolls back; the caller returns `before`, the committed state (INT-003)
    }
    return queries.InsertAuditLog(ctx, sqlc.InsertAuditLogParams{
        Action: "update", ObjectType: "product", ObjectID: id,
        ActorID: actor.ID(ctx), Changes: changes,
    })
})
```

### INT-002 Record who changed what, field by field

- **Severity:** must
- **Principle:** P7
- **Check:** inserts or updates that do not set `created_by` / `updated_by` from `actor.ID(ctx)`; update audit entries without old and new values of the changed fields.

System operations (seeds, webhooks, jobs) use `SystemUserID`, never `uuid.Nil` by accident or a made-up user.

### INT-003 Skip no-op updates

- **Severity:** should
- **Principle:** P7
- **Check:** an update that writes, audits and broadcasts even when no field changed.

Compare old and new values; when nothing changed, return the current state without writing, auditing or broadcasting.

### INT-004 Delete users softly and remove their PII

- **Severity:** should
- **Principle:** P5
- **Check:** user rows hard-deleted (breaking audit trails and `created_by` references); or soft-deleted with email, name and credentials still stored.

```sql
-- name: SoftDeleteUser :exec
UPDATE users SET
    deleted_at = now(),
    active = false,
    username = 'deleted-' || id::text, -- the full id: a UUIDv7 prefix is a timestamp and collides
    email = NULL,
    name = NULL,
    password_hash = NULL,
    updated_by = @actor
WHERE id = @id AND deleted_at IS NULL;
```

`active = false` means suspended and recoverable; `deleted_at` set means the user asked to be deleted and their PII is gone. Keep their ID in `created_by` / `updated_by` columns so audit trails stay intact; the UI shows "deleted user".

### INT-005 Every query on a soft-deletable table filters deleted rows

- **Severity:** must
- **Principle:** P5
- **Check:** a query reading users (or any table with `deleted_at`) without `deleted_at IS NULL`, unless named for that purpose (`ListDeletedUsers`, admin restore).

A missing filter resurrects deleted accounts in lists, logins or broadcasts. Add a repository test that soft-deletes a row and asserts it is gone from every read path.

### INT-006 Block deletions that would orphan data

- **Severity:** must
- **Principle:** P5
- **Check:** delete paths without pre-flight checks for invariants such as "at least one admin" or "every business has an owner"; pre-flight checks whose errors are ignored; a check that runs outside the delete's transaction.

The rule belongs to the service; atomicity belongs to the repository. The service passes the rule as a pure function, and the repository locks, counts, calls it and deletes in one transaction. Checked outside the transaction, two concurrent deletes both pass.

```go
// in the service
func checkLastAdmin(target *model.User, activeAdmins int) error {
    if target.Active && target.Role == model.RoleAdmin && activeAdmins == 1 {
        return fmt.Errorf("cannot delete the last admin; promote another first: %w", model.ErrConflict)
    }
    return nil
}

func (s *UserService) Delete(ctx context.Context, id uuid.UUID) error {
    return s.options.UserRepository.Delete(ctx, id, checkLastAdmin)
}

// in the repository: lock the target and the admins, count, ask the guard, delete
func (r *UserRepository) Delete(ctx context.Context, id uuid.UUID, guard func(target *model.User, activeAdmins int) error) error
```

### INT-007 Seed canonical data per entry, idempotently

- **Severity:** must
- **Principle:** P5, P6
- **Check:** seeding guarded by "table is empty"; seed errors ignored; seeds that overwrite admin changes on every start.

"Seed when empty" never restores a single deleted default. Ensure each entry on its own at startup, before serving:

```sql
-- name: EnsureTemplate :execrows
INSERT INTO templates (name_en, name_de, created_by, updated_by)
VALUES (@name_en, @name_de, @actor, @actor)
ON CONFLICT (name_en) DO NOTHING;
```

A default the admin wants gone is deactivated (`active = false`), not deleted, so it stays retired.

### INT-008 Sync external state on read, degrade to the cached value

- **Severity:** should
- **Principle:** P6
- **Check:** locally cached external state (payment status, subscription) that is only updated by webhooks; a read path that fails when the external API is down.

Name the read for what it does (`RefreshSubscription`, FUN-002). Read the local copy, refresh it from the provider, persist a changed value, and on provider failure return the local copy and record the failure on the wide event with `degraded=true` (LOG-002). Webhooks correct drift in between.
