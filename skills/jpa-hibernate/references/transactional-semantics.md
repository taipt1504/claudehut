# @Transactional Semantics

## Propagation

| Value | Behavior |
|-------|----------|
| `REQUIRED` (default) | Join existing tx or create new |
| `REQUIRES_NEW` | Always create new tx; suspend caller's |
| `MANDATORY` | Must be called within existing tx, else exception |
| `NESTED` | Nested tx with savepoint (DB-dependent) |
| `NEVER` | Must NOT be in tx, else exception |
| `SUPPORTS` | Use tx if present, else non-tx |
| `NOT_SUPPORTED` | Suspend caller's tx; run without |

Default `REQUIRED` is right 90% of cases.

`REQUIRES_NEW`: audit logging that must commit even if outer tx rolls back.

## Isolation

| Value | Behavior |
|-------|----------|
| `DEFAULT` | DB default (Postgres: READ_COMMITTED) |
| `READ_UNCOMMITTED` | Dirty reads allowed |
| `READ_COMMITTED` | No dirty reads |
| `REPEATABLE_READ` | Same query returns same result within tx |
| `SERIALIZABLE` | Full isolation; slowest |

Postgres default `READ_COMMITTED` is safe for most cases. Use `SERIALIZABLE` for strict invariants (banking).

## Rollback rules

```java
@Transactional(rollbackFor = Exception.class)  // rollback on ANY exception
public void process() { ... }

@Transactional(noRollbackFor = BusinessRuleException.class)  // commit despite this exception
public void process() { ... }
```

Default: rollback on `RuntimeException` + `Error`; NOT on checked `Exception`.

Most domain exceptions extend RuntimeException → default works.

## Read-only optimization

```java
@Transactional(readOnly = true)
public Page<User> list(Pageable pageable) { ... }
```

Hints to driver/DB:
- Hibernate skips dirty-check.
- Postgres may use replica.
- Connection pool may use read-only connection.

Always mark query-only methods.

## Timeout

```java
@Transactional(timeout = 5)  // seconds
public Order place(OrderRequest req) { ... }
```

DB-enforced. Use to bound long-running tx.

## AOP requirement

`@Transactional` works via AOP proxy. Only intercepted when:

- Annotated method is public.
- Method called from OUTSIDE the class (not self-invocation).

Self-invocation pitfall:

```java
public class UserService {
    public void publicMethod() {
        this.transactionalMethod();   // NOT intercepted — same class
    }

    @Transactional
    public void transactionalMethod() { ... }
}
```

Workaround: inject self via interface, or use AspectJ weaving.

## Connection scope

A `@Transactional` method holds a DB connection from begin to commit. Long methods → connection pool starvation.

Bad pattern:

```java
@Transactional
public Result process() {
    Data data = repo.findById(id);
    Result r = externalClient.fetch(data);  // 30s HTTP call holds connection
    repo.save(transform(r));
    return r;
}
```

Better: restructure to release connection during external call.

```java
public Result process() {
    Data data = txTemplate.execute(s -> repo.findById(id));
    Result r = externalClient.fetch(data);
    txTemplate.execute(s -> repo.save(transform(r)));
    return r;
}
```

## Anti-patterns

- `@Transactional` on private method → not intercepted
- Self-invocation of `@Transactional` method → not intercepted
- Long-held tx around external HTTP/RPC → connection pool starvation
- Catching exception inside `@Transactional` → tx committed despite intent
- `propagation = REQUIRES_NEW` for child operation that doesn't need atomicity → unnecessary connection acquisition
- Read-heavy method without `readOnly = true` → wastes Hibernate cycles
