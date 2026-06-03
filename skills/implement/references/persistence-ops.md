# DB migrations + indexing + connection pooling (companion to `claudehut:implement`)

<!-- Researched via Flyway (/flyway/flyway · context7) and HikariCP (/brettwooldridge/hikaricp · context7).
     Cross-checked against project rules: flyway-naming.md, migration-safety.md, indexing.md, connection-pool.md.
     Target: Spring Boot 3.2+ / Java 17+ / Postgres (primary) + MySQL (noted). -->

**When:** `db/migration/V*.sql`, `R*.sql`, `application*.yml` (datasource / pool), index design.

---

## DO

### Flyway naming
- `V<timestamp><seq>__snake_case_verb_noun.sql` — e.g. `V20260603001__add_tenant_id_to_users.sql`
- Use timestamp format (`YYYYMMDDNNN`) — immune to branch merge conflicts.
- Two underscores between version and description; lowercase snake_case description.
- `R__snake_case_name.sql` for views, functions, stored procedures, idempotent seed data.
- `.sql` extension only (not `.SQL`, not `.psql`).

### Migration safety (online-safe DDL)
- `CREATE INDEX CONCURRENTLY` for every new index on a table with existing rows (Postgres).
- New required column → 3 steps: ① ADD COLUMN nullable, ② backfill app-side in batches, ③ SET NOT NULL.
- Rename column via expand-contract: add new column → dual-write → drop old (two separate migrations).
- Document rollback in commit message or pair with `U<version>__<desc>.sql` (Flyway Teams).
- Annotate migration with `-- flyway: executeInTransaction=false` (or use Flyway callback) when using `CONCURRENTLY`.
- Test on Testcontainers Postgres with production-representative row counts.

### Index design
- Add an index when a column appears in WHERE, JOIN, or ORDER BY of a frequent query.
- Composite index: put equality columns first, range/sort column last.
- Covering index: INCLUDE non-filtered columns to achieve index-only scans.
- Partial index: add `WHERE status = 'PENDING'` to shrink index size for dominant query shapes.
- Always run `EXPLAIN (ANALYZE, BUFFERS)` before shipping; look for `Index Scan` vs `Seq Scan`.
- Monitor unused indexes (`idx_scan = 0`) and drop them — every index has a write-time cost.

### HikariCP (JDBC, Spring Boot 3.2+)
- Size pool: `maximum-pool-size = cpu_cores * 2` (SSD baseline); tune up under load, not speculatively.
- Keep `minimum-idle` at 20–30 % of `maximum-pool-size` to avoid cold-start latency.
- Set `connection-timeout` below your request SLA (≤ 3 s is safe for most services).
- Set `leak-detection-threshold` to 30 s in non-prod; enables in prod at 60 s if suspected leaks.
- Set `max-lifetime` to ~30 min — below Postgres `tcp_keepalives_idle` + firewall timeouts.
- Enable JMX / Prometheus metrics to alert on `hikaricp.connections.pending > 0`.

### R2DBC pool (reactive, Spring Boot 3.2+)
- Pool can be smaller than HikariCP — one connection serves many concurrent operations.
- `max-acquire-time` replaces `connectionTimeout`; keep it ≤ 3 s.
- Match `max-life-time` to HikariCP max-lifetime for parity with DBA firewall rules.

---

## DON'T

- **Never edit an applied migration.** Flyway checksums will fail on every subsequent environment and deployment.
- `CREATE INDEX` without `CONCURRENTLY` on a table with rows → exclusive lock, blocked writes.
- `ALTER TABLE … ADD COLUMN … NOT NULL` without a DEFAULT on a table with rows → immediate error.
- `RENAME COLUMN` in a single step on a live table → old app code breaks during rolling deploy.
- `DROP COLUMN` before all app instances stop reading it.
- Use `R__` files for table DDL — those belong in `V__` files.
- Oversize the pool: `10 instances × 50 pool = 500 connections` can exceed Postgres `max_connections` (default 100). Use PgBouncer.
- Leave `connection-timeout` at the Hikari default of 30 s — masks DB saturation; errors arrive late.
- Index low-cardinality columns (boolean flags) without a partial `WHERE` clause.
- Put a function on an indexed column in WHERE: `WHERE LOWER(email) = ?` defeats the index unless a functional index exists.

---

## Correct example

### Three-step nullable → NOT NULL migration

```sql
-- V20260603001__add_tenant_id_to_users.sql
-- Step 1: add nullable (zero-lock on Postgres 11+)
ALTER TABLE users ADD COLUMN tenant_id UUID;
-- NOTE: flyway: executeInTransaction=false required for CONCURRENTLY below
CREATE INDEX CONCURRENTLY idx_users_tenant_id ON users(tenant_id);
```

```java
// Step 2: app-side batched backfill (ApplicationRunner, runs after Flyway)
@Component
public class TenantBackfillRunner implements ApplicationRunner {
    private final JdbcTemplate jdbc;
    public void run(ApplicationArguments args) throws InterruptedException {
        int updated;
        do {
            updated = jdbc.update("""
                UPDATE users
                   SET tenant_id = (SELECT o.tenant_id FROM org o WHERE o.id = users.org_id)
                 WHERE id IN (SELECT id FROM users WHERE tenant_id IS NULL LIMIT 10_000)
            """);
            Thread.sleep(100);
        } while (updated > 0);
    }
}
```

```sql
-- V20260610001__make_tenant_id_not_null.sql
-- Step 3: enforce constraint after backfill verified
ALTER TABLE users ALTER COLUMN tenant_id SET NOT NULL;
```

### Composite + covering index

```sql
-- V20260603002__add_orders_composite_index.sql
-- equality cols first (user_id, status), range col last (created_at)
-- INCLUDE avoids heap fetch for the common projection
CREATE INDEX CONCURRENTLY idx_orders_user_status_date
    ON orders(user_id, status, created_at)
    INCLUDE (total_cents, currency);
```

### Partial index

```sql
-- V20260603003__add_orders_pending_index.sql
CREATE INDEX CONCURRENTLY idx_orders_pending_created
    ON orders(created_at)
    WHERE status = 'PENDING';
```

### HikariCP — Spring Boot `application.yml`

```yaml
spring:
  datasource:
    url: jdbc:postgresql://db:5432/myapp
    hikari:
      maximum-pool-size: 16          # 8-core host × 2
      minimum-idle: 4
      connection-timeout: 3000       # 3 s — must be < request SLA
      validation-timeout: 250        # floor is 250 ms per Hikari source
      idle-timeout: 600000           # 10 min
      max-lifetime: 1800000          # 30 min
      keepalive-time: 120000         # 2 min (Hikari default; keep < firewall idle timeout)
      leak-detection-threshold: 30000  # 30 s; log warning if connection held longer

management:
  metrics:
    export:
      prometheus:
        enabled: true
```

### R2DBC pool — `application.yml`

```yaml
spring:
  r2dbc:
    url: r2dbc:postgresql://db:5432/myapp
    pool:
      initial-size: 5
      max-size: 20
      max-acquire-time: 3s
      max-create-connection-time: 5s
      max-idle-time: 10m
      max-life-time: 30m
```

### MySQL online DDL

```sql
-- MySQL InnoDB: explicit ALGORITHM avoids implicit table copy + rebuild
ALTER TABLE users
    ADD COLUMN tenant_id BINARY(16),
    ALGORITHM=INPLACE, LOCK=NONE;

-- Index add (MySQL 8+, InnoDB online DDL)
ALTER TABLE users
    ADD INDEX idx_users_tenant_id (tenant_id),
    ALGORITHM=INPLACE, LOCK=NONE;
```

### EXPLAIN ANALYZE

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT user_id, status, created_at, total_cents, currency
  FROM orders
 WHERE user_id = '018f...' AND status = 'PENDING'
 ORDER BY created_at DESC;
-- Want: "Index Only Scan using idx_orders_user_status_date" — no heap fetch
-- Red flag: "Seq Scan" on large table, rows estimated ≪ actual (stale stats → ANALYZE)
```

---

## Anti-pattern

```sql
-- BAD: locks table during index build (minutes on large tables)
CREATE INDEX idx_users_email ON users(email);

-- BAD: ADD NOT NULL without default fails if any row exists
ALTER TABLE users ADD COLUMN tenant_id UUID NOT NULL;

-- BAD: single-step rename breaks in-flight requests during rolling deploy
ALTER TABLE users RENAME COLUMN old_email TO email;

-- BAD: function defeats index — use a functional index instead
SELECT * FROM users WHERE LOWER(email) = 'foo@example.com';
-- FIX: CREATE INDEX idx_users_email_lower ON users(LOWER(email));
```

```yaml
# BAD: Hikari defaults — too slow to surface DB saturation
spring:
  datasource:
    hikari:
      connection-timeout: 30000   # 30 s default — masks problems
      maximum-pool-size: 10       # default; likely wrong for production
      # leak-detection-threshold not set → silent connection leaks
```

---

## Gotchas / version notes

- **Flyway + `CONCURRENTLY`**: `CREATE INDEX CONCURRENTLY` cannot run inside a transaction. Annotate the file with `-- flyway: executeInTransaction=false` (Flyway 9+) or implement a `FlywayCallback` that calls `connection.setAutoCommit(true)` for that migration.
- **Flyway out-of-order**: disabled by default. Enable only when cherry-picking across branches (`spring.flyway.out-of-order: true`). Leaves gaps in history — use timestamp versions to avoid this entirely.
- **HikariCP `validationTimeout` floor**: hard-coded minimum 250 ms in Hikari source (`SOFT_TIMEOUT_FLOOR`). Setting lower is silently ignored.
- **HikariCP `minIdle = -1` default**: when not set, Hikari matches `minIdle` to `maxPoolSize` (fixed pool). Set `minimum-idle` explicitly to allow pool shrinkage during off-peak.
- **Postgres `max_connections`**: default is 100. With multiple service instances, total pool slots can exceed this. Use PgBouncer (transaction-mode pooling) as a multiplexer in front of Postgres.
- **R2DBC vs HikariCP pool sizing**: R2DBC is non-blocking; a single connection handles many concurrent operations. A `max-size` of 20 often matches the throughput of a HikariCP pool of 50+ for I/O-bound workloads.
- **Partial index and query planner**: Postgres uses a partial index only when the WHERE predicate in the query exactly matches (or implies) the index predicate. `WHERE status = 'PENDING'` must appear literally; parameterized `WHERE status = $1` may not bind the partial index — check with `EXPLAIN`.
- **MySQL ALGORITHM=INPLACE limits**: not all DDL supports INPLACE (e.g., changing a column's data type usually requires COPY). If `ALGORITHM=INPLACE` fails, MySQL errors immediately rather than silently falling back — which is the desired behavior in a migration.
- **Expand-contract rename timing**: the "contract" (drop old column) migration must not be deployed until all app instances are confirmed read-free on the old column. Use a feature flag or two separate deploys.
- **Spring Boot 3.2+ Flyway auto-config**: `spring.flyway.locations` defaults to `classpath:db/migration`. Override only when using multi-module layouts. Flyway bean is auto-configured before `ApplicationRunner` beans, so backfill runners are safe to run post-migration.
