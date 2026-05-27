---
id: rules/framework/migration-safety
paths:
  - "**/db/migration/V*.sql"
severity: critical
tags: [flyway, migration, online-safety]
---


# Migration Safety

## DO

- `CREATE INDEX CONCURRENTLY` on production tables.
- Nullable column + backfill + NOT NULL (3-step) for new required columns on large tables.
- Expand-contract for renames.
- Document rollback in commit message OR sibling `U__` migration (Flyway Teams).
- Test migration on Testcontainers Postgres with realistic data volume.

## DON'T

- `CREATE INDEX` without `CONCURRENTLY` on large tables → table lock.
- `ALTER TABLE ... ADD COLUMN ... NOT NULL` without DEFAULT on large tables → fails on rolling deploy.
- `DROP COLUMN` while app code still reads it.
- `RENAME COLUMN` in single migration on hot table.
- Edit a committed migration (history forks per environment).

## Correct examples

### Add nullable column + concurrent index

```sql
-- V20250527001__add_tenant_id_to_users.sql
ALTER TABLE users ADD COLUMN tenant_id UUID;
CREATE INDEX CONCURRENTLY idx_users_tenant_id ON users(tenant_id);
```

### Backfill in batches (separate runner)

App-side migration runner:

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
            Thread.sleep(100);
        } while (updated > 0);
    }
}
```

### Apply NOT NULL after backfill complete

```sql
-- V20250528001__make_tenant_id_required.sql
ALTER TABLE users ALTER COLUMN tenant_id SET NOT NULL;
```

### Expand-contract rename

```sql
-- V20250527001__expand_add_email.sql
ALTER TABLE users ADD COLUMN email VARCHAR(254);
UPDATE users SET email = old_email WHERE email IS NULL;

-- App code: write both columns, read new
-- (deploy + ensure no app reads old_email)

-- V20250601001__contract_drop_old_email.sql
ALTER TABLE users DROP COLUMN old_email;
```

## Incorrect examples

```sql
-- BAD — NOT NULL without DEFAULT on existing table
ALTER TABLE users ADD COLUMN tenant_id UUID NOT NULL;
-- Fails immediately if any rows exist

-- BAD — CREATE INDEX locks table during build
CREATE INDEX idx_users_email ON users(email);
-- For large table → minutes of blocked writes

-- BAD — RENAME in one step
ALTER TABLE users RENAME COLUMN old_email TO email;
-- Old app code reads old_email → 500 errors during rolling deploy
```

## MySQL specifics

```sql
ALTER TABLE users ADD COLUMN tenant_id BINARY(16),
                  ALGORITHM=INPLACE, LOCK=NONE;
```

Without `ALGORITHM=INPLACE, LOCK=NONE`, MySQL falls back to copy + rebuild (blocking).

## Validation

`scripts/validate-migration.sh` (in `claudehut:flyway-migration` skill) enforces:

- Naming pattern.
- No `CREATE INDEX` without CONCURRENTLY.
- No `ADD COLUMN NOT NULL` without DEFAULT.
- Warnings on RENAME / DROP / TRUNCATE / LOCK TABLE.

PreToolUse hook invokes validator on every migration write. Critical issues block via `permissionDecision: "deny"`.

## References

- See `claudehut:flyway-migration` skill.
- `claudehut-migration-validator` agent runs this rule.
- Phase 5 reviewer-db also runs `EXPLAIN ANALYZE` on dev DB if Postgres MCP available.
