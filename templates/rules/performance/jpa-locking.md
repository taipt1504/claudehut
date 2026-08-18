---
id: rules/performance/jpa-locking
paths:
  - "**/*Repository.java"
stack: "orm=jpa"
severity: high
tags: [jpa, locking, concurrency, spring-data]
---
<!-- ClaudeHut rule template — generated into .claude/rules/performance/jpa-locking.md by claudehut-init. -->

# Spring Data JPA Locking Rule

The database-level semantics live in `performance/postgres-locking`. This rule is the **Spring Data JPA**
mechanics for expressing them, and applies only to a JPA project — the annotations below do not exist in
an R2DBC stack.

## Lock mode decision table

| Use case | SQL clause | Spring Data JPA |
|---|---|---|
| Job-queue / outbox poll — skip contended rows | `FOR UPDATE SKIP LOCKED` | `@Lock(PESSIMISTIC_WRITE)` + `@QueryHints` |
| Fail fast under contention (circuit-break) | `FOR UPDATE NOWAIT` | `@Lock(PESSIMISTIC_WRITE)` + timeout `0` |
| Normal pessimistic read-modify-write | `FOR UPDATE` | `@Lock(PESSIMISTIC_WRITE)` |
| Singleton scheduled job (no table needed) | `pg_advisory_xact_lock(key)` | native query in `@Transactional` |

## SKIP LOCKED — job-queue / outbox polling

```java
@Lock(LockModeType.PESSIMISTIC_WRITE)
@QueryHints(@QueryHint(name = "jakarta.persistence.lock.timeout", value = "-2"))
@Query("SELECT e FROM OutboxEntry e WHERE e.published = false ORDER BY e.id LIMIT :n")
List<OutboxEntry> pollUnpublished(@Param("n") int n);
```

`-2` is the SKIP LOCKED hint value. The hint key is `jakarta.persistence.*` on a Jakarta baseline —
`javax.persistence.*` is the Hibernate 5 name and is silently ignored under Hibernate 6.

## NOWAIT — fail fast under contention

```java
@Lock(LockModeType.PESSIMISTIC_WRITE)
@QueryHints(@QueryHint(name = "jakarta.persistence.lock.timeout", value = "0"))
@Query("SELECT e FROM Entity e WHERE e.id = :id")
Optional<Entity> findByIdForUpdateNowait(@Param("id") UUID id);
// Throws QueryTimeoutException immediately if the row is locked — caller retries or returns 409
```

Use for payment capture and inventory decrement — anywhere "wait silently" is the wrong behaviour.

## Advisory locks — singleton jobs

```java
@Transactional
public void runOnce(long lockKey) {
    entityManager.createNativeQuery("SELECT pg_advisory_xact_lock(:key)")
        .setParameter("key", lockKey)
        .getSingleResult();
    // safe: only one JVM proceeds; the lock releases at commit/rollback
}
```

## Anti-patterns

- `FOR UPDATE` inside `@Transactional(readOnly = true)` — Hibernate may drop the lock hint. Use a write
  transaction.
- A `@Lock` annotation on a derived query method that Spring Data turns into a `SELECT` without the
  intended `FOR UPDATE`; verify the generated SQL, do not assume it.
- `javax.persistence.lock.timeout` as the hint key on Hibernate 6 — wrong package, no effect, no error.
