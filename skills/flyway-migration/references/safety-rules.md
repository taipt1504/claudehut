# Migration Safety Rules

## Online-safe DDL — PostgreSQL

| Operation | Safe? | Notes |
|-----------|-------|-------|
| `CREATE TABLE` | ✓ | New table, no locking existing |
| `ADD COLUMN` (nullable, no default) | ✓ | Metadata-only on Postgres 11+ |
| `ADD COLUMN ... NOT NULL DEFAULT x` | ✓ on Postgres 11+ | Rewrites table on older versions |
| `ADD COLUMN ... NOT NULL` (no default) | ✗ | Fails if rows exist |
| `DROP COLUMN` | ✗ during rolling deploy | App still reading it; expand-contract |
| `ALTER COLUMN TYPE` | sometimes | Compatible types (varchar size up) safe; rewrites for incompatible |
| `RENAME COLUMN` | ✗ during rolling deploy | App reads old name; expand-contract |
| `CREATE INDEX` | ✗ on large tables | Locks; use `CONCURRENTLY` |
| `CREATE INDEX CONCURRENTLY` | ✓ | No table lock |
| `DROP INDEX` | ✓ | Brief lock |
| `DROP INDEX CONCURRENTLY` | ✓ | Truly online |
| `ADD CONSTRAINT NOT NULL` (with check) | partial | Use `NOT VALID` + `VALIDATE` separately |
| `TRUNCATE` | ✗ | Acquires `ACCESS EXCLUSIVE` lock |

## Expand-contract pattern (renames)

Renaming `user_email` → `email`:

**Migration V100__expand_add_email.sql:**
```sql
ALTER TABLE users ADD COLUMN email VARCHAR(254);
-- Backfill: copy from user_email
UPDATE users SET email = user_email WHERE email IS NULL;
```

App reads both columns, writes both.

**After deploy completes, V101__contract_drop_user_email.sql:**
```sql
-- App now uses 'email' only; safe to drop
ALTER TABLE users DROP COLUMN user_email;
```

## Backfill in batches

For large tables, single `UPDATE` locks too long:

```sql
-- V100__add_tenant_id_column.sql (online-safe: nullable add + concurrent index)
ALTER TABLE users ADD COLUMN tenant_id UUID;
CREATE INDEX CONCURRENTLY idx_users_tenant_id ON users(tenant_id);

-- Backfill via separate Java migration or batched updates outside Flyway
```

Backfill via Java migration (callable from app):

```java
@Component
public class TenantBackfillRunner implements ApplicationRunner {
    public void run(ApplicationArguments args) {
        int updated;
        do {
            updated = jdbc.update("""
                UPDATE users SET tenant_id = (
                    SELECT tenant_id FROM organization o WHERE o.id = users.org_id
                )
                WHERE id IN (SELECT id FROM users WHERE tenant_id IS NULL LIMIT 10000)
            """);
            sleep(100);  // breathe
        } while (updated > 0);
    }
}
```

Then V101 adds NOT NULL:

```sql
-- V101__make_tenant_id_required.sql
ALTER TABLE users ALTER COLUMN tenant_id SET NOT NULL;
```

## Rollback

Flyway has limited automatic rollback. For critical migrations, sibling undo:

```
V100__add_tenant_id_column.sql
U100__rollback_add_tenant_id_column.sql
```

`U` files require Flyway Teams edition; for community, document manually:

```sql
-- V100__add_tenant_id_column.sql
-- ROLLBACK:
--   ALTER TABLE users DROP COLUMN tenant_id;
--   DROP INDEX idx_users_tenant_id;

ALTER TABLE users ADD COLUMN tenant_id UUID;
CREATE INDEX CONCURRENTLY idx_users_tenant_id ON users(tenant_id);
```

## MySQL specifics

```sql
ALTER TABLE users ADD COLUMN tenant_id BINARY(16),
                  ALGORITHM=INPLACE, LOCK=NONE;
```

`ALGORITHM=INPLACE, LOCK=NONE` for online schema change. If not supported, MySQL falls back to copy + rebuild.

## Validation

`scripts/validate-migration.sh` runs static checks. Phase 5 reviewer-db deepens analysis with Postgres MCP `EXPLAIN`.
