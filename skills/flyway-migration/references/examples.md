# Migration Examples

## Example 1 — Add nullable column + concurrent index

```sql
-- V20250527001__add_tenant_id_to_users.sql
-- Purpose: prepare users for multi-tenant
-- ROLLBACK:
--   ALTER TABLE users DROP COLUMN tenant_id;
--   DROP INDEX IF EXISTS idx_users_tenant_id;

ALTER TABLE users ADD COLUMN tenant_id UUID;
CREATE INDEX CONCURRENTLY idx_users_tenant_id ON users(tenant_id);
```

Note: `CREATE INDEX CONCURRENTLY` cannot run inside a transaction. Mark Flyway migration `transactional: false`:

```yaml
spring:
  flyway:
    sql-migration-prefix: V
    out-of-order: false
```

Or add config per-migration via callback.

## Example 2 — Expand-contract rename

### Phase 1: expand (V100__add_new_column.sql)

```sql
ALTER TABLE users ADD COLUMN email_address VARCHAR(254);
UPDATE users SET email_address = email WHERE email_address IS NULL;
```

App code: writes BOTH `email` and `email_address`. Reads `email_address` if present, else `email`.

### Deploy app version that writes both

(no migration here — code change only)

### Phase 2: contract (V110__drop_old_column.sql)

After confirming app exclusively uses `email_address`:

```sql
ALTER TABLE users DROP COLUMN email;
```

## Example 3 — Add NOT NULL with backfill (3-step)

### V200__add_nullable_status.sql

```sql
ALTER TABLE orders ADD COLUMN status VARCHAR(20);
CREATE INDEX CONCURRENTLY idx_orders_status ON orders(status);
```

### Backfill (Java runner, NOT a SQL migration)

```java
@Component
public class OrderStatusBackfill implements ApplicationRunner {
    public void run(ApplicationArguments args) {
        int updated;
        do {
            updated = jdbc.update("""
                UPDATE orders
                SET status = CASE WHEN shipped_at IS NOT NULL THEN 'SHIPPED' ELSE 'PENDING' END
                WHERE id IN (SELECT id FROM orders WHERE status IS NULL LIMIT 10000)
            """);
            Thread.sleep(100);
        } while (updated > 0);
    }
}
```

### V210__set_status_not_null.sql

(after backfill completes via deploy)

```sql
ALTER TABLE orders ALTER COLUMN status SET NOT NULL;
```

## Example 4 — Reference data seed (repeatable)

```sql
-- R__seed_countries.sql
INSERT INTO countries (code, name)
VALUES ('US', 'United States'), ('GB', 'United Kingdom'), ('VN', 'Vietnam')
ON CONFLICT (code) DO UPDATE SET name = EXCLUDED.name;
```

R__ migrations re-run on checksum change → safe to evolve seed list.

## Example 5 — View (R__)

```sql
-- R__view_active_users.sql
CREATE OR REPLACE VIEW active_users AS
SELECT id, email, name, last_login
FROM users
WHERE deleted_at IS NULL AND last_login > NOW() - INTERVAL '90 days';
```
