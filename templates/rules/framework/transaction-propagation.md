---
id: rules/framework/transaction-propagation
paths:
  - "**/*Service.java"
  - "**/*ServiceImpl.java"
severity: high
tags: [transactions, spring, jpa]
---
<!-- ClaudeHut rule template — generated into .claude/rules/framework/transaction-propagation.md by claudehut-init. Reused & enhanced from committed rules/framework/transaction-propagation.md. -->

# Spring @Transactional — Propagation & Isolation

## Propagation decision table

| Propagation | Use when | Sharp risk |
|---|---|---|
| `REQUIRED` (default) | Most service methods — join caller's tx or start one | None; safe default |
| `REQUIRES_NEW` | Audit log, outbox entry **must** commit even if outer tx rolls back | Suspends outer tx: holds **2 pool connections** simultaneously; if REQUIRES_NEW touches rows locked by outer tx → **deadlock**. Never use in a loop. |
| `MANDATORY` | Low-level helper that must never be called without a tx (enforcement) | Throws `IllegalTransactionStateException` if no tx active — intended |
| `NOT_SUPPORTED` | Long reporting query inside a tx-heavy service; avoid lock escalation | Suspends outer tx; Hibernate session detaches |
| `NEVER` | Code that must run outside any tx (e.g., batch streaming) | Throws if tx active |
| `SUPPORTS` | Read-only DAO utility; works with or without tx | Inconsistent behaviour across callers — prefer explicit |

## Critical failure modes

### 1. Self-invocation bypasses the proxy

```java
// BROKEN — proxy not involved, @Transactional on save() ignored
public void create(Order o) { this.save(o); }

@Transactional
public void save(Order o) { repo.save(o); }
```

Fix: inject self (`@Autowired private OrderService self`) **or** split into two beans.

### 2. Checked exceptions do NOT roll back by default

```java
@Transactional                                  // rolls back only RuntimeException
public void transfer() throws InsufficientFundsException { ... }

// Fix:
@Transactional(rollbackFor = Exception.class)   // roll back on any Throwable subtype
public void transfer() throws InsufficientFundsException { ... }
```

Rule: add `rollbackFor = Exception.class` whenever the method signature declares a checked exception.

### 3. readOnly=true on queries

```java
@Transactional(readOnly = true)
public List<Order> findPending() { return repo.findByStatus(PENDING); }
```

Benefits: Hibernate skips dirty-check flush; JDBC driver/load-balancer can route to replica.
Risk: none — read-only flag is a hint, silently ignored if unsupported.

### 4. Listener methods — one tx per message

```java
// WRONG — one tx wraps the whole batch; any failure rolls back all
@Transactional
@KafkaListener(topics = "orders")
public void onBatch(List<ConsumerRecord<?,?>> records) { ... }

// CORRECT — delegate to a @Transactional service method per record
@KafkaListener(topics = "orders")
public void onBatch(List<ConsumerRecord<?,?>> records) {
    records.forEach(r -> orderService.process(r.value()));
}
```

### 5. Timeout

```java
@Transactional(timeout = 30)   // seconds; -1 = driver default
```

Set to **p99 query time × 2**. Expiry throws `TransactionTimedOutException` (RuntimeException → auto-rollback). Do not set globally — tune per method.

## Isolation levels

| Level | PG default | MySQL/InnoDB default | Dirty read | Non-repeatable | Phantom |
|---|---|---|---|---|---|
| `READ_UNCOMMITTED` | — | — | yes | yes | yes |
| `READ_COMMITTED` | **default** | — | no | yes | yes |
| `REPEATABLE_READ` | — | **default** | no | no | yes |
| `SERIALIZABLE` | — | — | no | no | no |

`ISOLATION_DEFAULT` delegates to the driver default (READ_COMMITTED on PG; REPEATABLE_READ on MySQL InnoDB).

**When to escalate:**

- `REPEATABLE_READ` on PG: aggregate + later insert in same tx must see stable snapshot (financial summaries, inventory checks).
- `SERIALIZABLE`: true serializability required (e.g., "insert only if not exists" without a unique constraint) — throughput penalty ~20–40%; use only on narrow, short transactions.

## When NOT to annotate

- `@Transactional` on `private` or `final` methods — proxy cannot intercept; silently no-ops with Spring AOP.
- Repository interface methods — Spring Data already wraps each in a tx; double-wrapping is harmless but misleading.
- Huge batch operations — one tx per 1k rows, not one tx for the whole table; use `REQUIRES_NEW` in a loop **sparingly** (pool exhaustion risk above ~10 concurrent callers).

## Quick-reference snippet

```java
@Service
@RequiredArgsConstructor
public class OrderService {

    @Transactional(rollbackFor = Exception.class, timeout = 30)
    public Order create(CreateOrderRequest req) throws OrderException { ... }

    @Transactional(readOnly = true)
    public List<Order> findByUser(UUID userId) { ... }

    @Transactional(propagation = REQUIRES_NEW, rollbackFor = Exception.class)
    public void writeAuditLog(AuditEntry entry) { ... }  // injected separate bean
}
```

## References

- See `claudehut:implement` skill for outbox + saga patterns.
