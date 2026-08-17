---
id: rules/performance/postgres-locking
paths:
  - "**/*Repository.java"
  - "**/db/migration/V*.sql"
stack: "db=postgresql"
severity: high
tags: [postgres, locking, concurrency]
---
<!-- ClaudeHut rule template — generated into .claude/rules/performance/postgres-locking.md by claudehut-init. Reused & enhanced from committed rules/performance/postgres-locking.md. -->

# PostgreSQL Locking

## Lock mode decision table

| Use case | SQL clause |
|---|---|
| Job-queue / outbox poll — skip contended rows | `FOR UPDATE SKIP LOCKED` |
| Fail fast under contention (circuit-break) | `FOR UPDATE NOWAIT` |
| Normal pessimistic read-modify-write | `FOR UPDATE` |
| Singleton scheduled job (no table needed) | `pg_advisory_xact_lock(key)` |

The Spring Data JPA way to express these is `performance/jpa-locking` — it loads only on a JPA project.
This rule is client-agnostic and applies to R2DBC and plain JDBC just as much.

## SKIP LOCKED — job-queue / outbox polling

```sql
SELECT * FROM outbox_entry
 WHERE published = false
 ORDER BY id
 LIMIT :n
   FOR UPDATE SKIP LOCKED;
```

`-2` is Hibernate's magic constant for `SKIP LOCKED`; alternatively use the string `"SKIP_LOCKED"` — both map to `FOR UPDATE SKIP LOCKED` on the Postgres dialect.

Native query alternative (always safe, dialect-agnostic in intent):

```sql
SELECT * FROM outbox_entry
WHERE published = false
ORDER BY id
LIMIT 50
FOR UPDATE SKIP LOCKED;
```

**Why SKIP LOCKED beats SELECT + UPDATE:** Single round-trip; no phantom re-lock; multiple pollers auto-partition the queue without coordination.

## NOWAIT — fail fast under contention

```sql
SELECT * FROM entity WHERE id = :id FOR UPDATE NOWAIT;
-- errors immediately (SQLSTATE 55P03) if the row is locked — caller retries or returns 409
```

Use for: payment capture, inventory decrement — anywhere "wait silently" is wrong.

## Advisory locks — singleton jobs

```sql
-- inside an explicit transaction: only one caller proceeds; released at commit/rollback
SELECT pg_advisory_xact_lock(:key);
```

**xact-scoped beats session-scoped** (`pg_advisory_lock`): session locks survive connection pooling hand-offs — a crashed pod leaks them until its DB session closes. Transaction-scoped locks auto-release on txn end, compatible with pgBouncer transaction-mode pooling.

## Deadlock prevention

Always acquire multiple row locks in the **same key order**:

```sql
-- GOOD: deterministic order eliminates deadlock
SELECT * FROM orders WHERE id = ANY(:ids)
ORDER BY id
FOR UPDATE;

-- BAD: concurrent txns lock in different orders → deadlock
```

Symptom in prod: `ERROR: deadlock detected` with alternating slow-transaction pairs. Postgres chooses a victim and rolls it back; application sees `PSQLException`.

## DDL locking — online migration rules

| Operation | Lock | Safe on live table? |
|---|---|---|
| `ADD COLUMN` nullable, no default | none (PG 11+) | Yes — metadata-only |
| `ADD COLUMN ... DEFAULT <literal>` | none (PG 11+) | Yes — stored in catalog |
| `ADD COLUMN NOT NULL` without default | `ACCESS EXCLUSIVE` | No — rewrites table |
| `CREATE INDEX` | `SHARE` | No — blocks writes |
| `CREATE INDEX CONCURRENTLY` | none blocking | Yes — 3-phase, ~2× slower |
| `ALTER COLUMN TYPE` | `ACCESS EXCLUSIVE` | No — full rewrite |

```sql
-- Migration preamble for any DDL on busy tables
SET lock_timeout = '2s';       -- abort rather than queue behind long txns
SET statement_timeout = '30s'; -- guard runaway DDL

CREATE INDEX CONCURRENTLY idx_outbox_published ON outbox_entry(published)
  WHERE published = false;
-- Note: CONCURRENTLY cannot run inside a transaction block.
-- Flyway: set executeInTransaction=false for this migration file.
```

## Lock monitoring

```sql
SELECT
    pid,
    now() - pg_stat_activity.query_start AS duration,
    query,
    state,
    wait_event_type,
    wait_event
FROM pg_locks
JOIN pg_stat_activity USING (pid)
WHERE NOT granted
ORDER BY duration DESC;
```

Long `wait_event = 'relation'` or `'tuple'` rows → contended lock; inspect the blocking pid's query column.

## When NOT to use pessimistic locks

| Scenario | Problem | Use instead |
|---|---|---|
| High-read, rare-conflict entities | Lock overhead > contention savings | Optimistic (`@Version`) |
| Cross-service coordination | DB lock doesn't span service boundary | Distributed lock (Redis Redlock) or outbox |
| Read-only queries | `FOR UPDATE` on read is wasteful | No lock |
| Long-running user workflows (minutes) | Holds DB connection in pool | Optimistic + conflict UI |

## Anti-patterns

- Missing `ORDER BY` on batch `SKIP LOCKED` select — non-deterministic; different pollers may compete for same rows on index scan without ordering guarantee.
- `pg_advisory_lock` (session-scoped) with pgBouncer transaction mode — lock leaks across pool hand-offs; use `pg_advisory_xact_lock` exclusively.
- `ALTER TABLE` without `lock_timeout` in migration — queues behind long-running queries, blocking all subsequent writers for the queue duration.
