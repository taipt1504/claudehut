---
id: rules/performance/indexing
applies-to: "**/db/migration/V*.sql"
severity: medium
tags: [database, indexing, query-performance]
---

# Database Indexing

## When to add an index

1. Column appears in WHERE clause of frequent query.
2. Column appears in JOIN.
3. Column appears in ORDER BY (with appropriate sort direction).
4. Foreign key column (for JOIN performance).

## When NOT to add

- Low-cardinality column (boolean) — index unhelpful.
- Small table (< 1k rows) — full scan faster.
- Write-heavy column (each write updates index).
- Speculative "we might need it" — adds maintenance cost.

## Composite index — column order matters

```sql
CREATE INDEX idx_orders_user_status_date ON orders(user_id, status, created_at);
```

Used for queries:
- `WHERE user_id = ?`
- `WHERE user_id = ? AND status = ?`
- `WHERE user_id = ? AND status = ? AND created_at > ?`
- `WHERE user_id = ? ORDER BY created_at` (with status anywhere — sort uses index)

NOT used for:
- `WHERE status = ?` alone (must start with leftmost column).
- `WHERE created_at > ?` alone.

## Covering index

Include extra columns to avoid table lookup:

```sql
CREATE INDEX idx_users_email_covering ON users(email) INCLUDE (name, active);
```

Query `SELECT email, name, active FROM users WHERE email = ?` reads only the index.

## Partial index

Index a subset of rows:

```sql
CREATE INDEX idx_orders_pending ON orders(created_at) WHERE status = 'PENDING';
```

Smaller, faster for the dominant query "find pending orders by date".

## EXPLAIN ANALYZE

Always check actual plan:

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM orders WHERE user_id = '...' AND status = 'PENDING';
```

Look for:
- `Index Scan` (good) vs `Seq Scan` (bad on large tables).
- `Index Cond` (using the index for filtering).
- Rows estimated vs actual — large divergence → vacuum/analyze.

## Index-only scan (Postgres)

If query reads only indexed columns → no table access:

```sql
CREATE INDEX idx_users_email ON users(email) INCLUDE (name);

SELECT email, name FROM users WHERE email = 'a@b.com';
-- Index-only scan, no heap fetch
```

## Index size

Monitor:

```sql
SELECT schemaname, tablename, indexname, pg_size_pretty(pg_relation_size(indexrelid))
FROM pg_stat_user_indexes
ORDER BY pg_relation_size(indexrelid) DESC LIMIT 20;
```

Unused indexes:

```sql
SELECT * FROM pg_stat_user_indexes
WHERE idx_scan = 0 AND schemaname = 'public';
```

## Creating index without lock

```sql
CREATE INDEX CONCURRENTLY idx_users_tenant_id ON users(tenant_id);
```

Slower, but no exclusive table lock. Use on production-sized tables.

In Flyway migration:

```sql
-- V20250527001__add_tenant_id_index.sql
CREATE INDEX CONCURRENTLY idx_users_tenant_id ON users(tenant_id);
```

Note: `CONCURRENTLY` cannot be inside a transaction. Configure Flyway with `transactional: false` per-migration or use callback.

## MySQL specifics

```sql
-- Online schema change with InnoDB
ALTER TABLE users ADD INDEX idx_users_tenant_id (tenant_id),
                  ALGORITHM=INPLACE, LOCK=NONE;
```

## Index maintenance

- `VACUUM ANALYZE` after large data changes (Postgres).
- `OPTIMIZE TABLE` (MySQL) — blocking, rarely needed.
- Reindex if bloat suspected: `REINDEX INDEX CONCURRENTLY ...`.

## Anti-patterns

- Index on every column "just in case" — write penalty.
- Wrong column order in composite — query doesn't use the index.
- Function on indexed column in WHERE: `WHERE LOWER(email) = ?` — defeats index unless functional index.
- Implicit type conversion: `WHERE user_id = 42` when `user_id` is varchar — defeats index.
- Index on column with low cardinality (boolean) without partial WHERE.
