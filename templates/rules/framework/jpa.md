---
id: rules/framework/jpa
paths:
  - "**/*Entity.java"
  - "**/*Repository.java"
stack: "orm=jpa"
severity: high
tags: [jpa, hibernate, n+1, lazy-load, pagination, optimistic-locking]
---
<!-- ClaudeHut rule template — generated into .claude/rules/framework/jpa.md by claudehut-init. Reused & enhanced from committed rules/framework/jpa.md. -->


# JPA / Hibernate Rules

## DO

- `FetchType.LAZY` **explicitly** on every association — `@ManyToOne`/`@OneToOne` default **EAGER**; always be explicit.
- `@EntityGraph` or `JOIN FETCH` for queries that need related data.
- `@BatchSize(size = 25)` (or `hibernate.default_batch_fetch_size=25`) as global lazy-collection safety net.
- `@Transactional(readOnly = true)` on every read-only service method (skips dirty-check flush, enables read replica routing).
- `@Transactional` at the **service layer** for writes; never on repository implementations.
- `@Version` (`Long` or `Integer`) on entities with concurrent writes.
- `equals`/`hashCode` via business key; `hashCode()` returns `getClass().hashCode()` — stable across the entity lifecycle.
- Return `Optional<T>` from finders; use DTO/interface projections for read-only list endpoints.
- Add `@Index` on every FK column.
- `@NoArgsConstructor` (protected minimum) — Hibernate requires it for proxying.

## DON'T

- `FetchType.EAGER` on collections — forces join on every load, breaks `Pageable` pagination.
- `@ManyToOne` / `@OneToOne` without explicit `fetch = FetchType.LAZY` — default is EAGER (surprise extra join).
- `JOIN FETCH` a collection with `Pageable` — Hibernate paginates **in memory** and emits `HHH90003004`; wrong results on large sets.
- `JOIN FETCH` two collections in one query — cartesian product; fetch one, batch the other.
- Access a lazy field outside a `@Transactional` boundary → `LazyInitializationException`.
- `@Data` on `@Entity` — Lombok's generated `equals`/`hashCode` walks every field including lazy relations → `LazyInitializationException`, hash mismatch post-persist, `StackOverflowError` on bidirectional `toString`.
- Call a `@Transactional` method on `this` — Spring proxy not invoked; transaction silently missing.
- Multiple `findById` calls in a loop — batch via `findAllById(ids)`.
- Use entity as `@RequestBody` / `@ResponseBody` — mass assignment and serialization hazards.
- `spring.jpa.open-in-view=true` (Boot default) — holds DB connection through view rendering; lazy-load bugs surface silently in the web layer.

## Critical hazards table

| Hazard | Symptom in prod | Fix |
|--------|-----------------|-----|
| `@ManyToOne` default EAGER | Extra JOIN on every parent load; latency spike under load | `fetch = FetchType.LAZY` explicit |
| `JOIN FETCH` + `Pageable` | `HHH90003004` warning; OOM on large result set | Fetch page of IDs → `@EntityGraph` by IDs |
| `open-in-view=true` | Connection pool exhaustion; lazy loads in view logs | `spring.jpa.open-in-view=false` |
| Self-invocation `@Transactional` | Write not rolled back on exception | Inject self or extract to separate bean |
| `@Data` on entity | `LazyInitializationException` / `StackOverflowError` | `@Getter @Setter @NoArgsConstructor @ToString(onlyExplicitlyIncluded=true)` |
| Id-based `hashCode` | Entity lost in `HashSet` after first `flush` | `return getClass().hashCode()` |
| `@Version` unhandled | Silent lost update at controller boundary | Catch `OptimisticLockingFailureException` → HTTP 409 |

## Boot config

```yaml
spring:
  jpa:
    open-in-view: false          # MUST disable — default true is a connection-leak footgun
    properties:
      hibernate.default_batch_fetch_size: 25
      hibernate.generate_statistics: true   # enable in test profile only
```

## Correct example

```java
@Entity
@Table(name = "orders", indexes = @Index(columnList = "user_id"))
@Getter @Setter @NoArgsConstructor
@ToString(onlyExplicitlyIncluded = true)
public class Order {

    @Id @GeneratedValue(strategy = GenerationType.UUID)
    @ToString.Include
    private UUID id;

    @Column(nullable = false, unique = true)
    @ToString.Include
    private String number;                    // business key

    @ManyToOne(fetch = FetchType.LAZY)        // explicit — default is EAGER
    @JoinColumn(name = "user_id")
    private User user;

    @OneToMany(mappedBy = "order", fetch = FetchType.LAZY)
    @BatchSize(size = 25)
    private Set<OrderLine> lines = new HashSet<>();

    @Version
    private Long version;

    @Override public boolean equals(Object o) {
        if (this == o) return true;
        if (!(o instanceof Order other)) return false;
        return number != null && number.equals(other.number);
    }
    @Override public int hashCode() { return getClass().hashCode(); }
}

@Repository
public interface OrderRepository extends JpaRepository<Order, UUID> {

    // Safe: @EntityGraph on Pageable (no in-memory pagination)
    @EntityGraph(attributePaths = {"lines"})
    Page<Order> findByUserId(UUID userId, Pageable pageable);

    // Safe: JOIN FETCH only on non-paginated query
    @Query("SELECT o FROM Order o JOIN FETCH o.lines WHERE o.user.id = :uid")
    List<Order> findWithLinesByUserId(@Param("uid") UUID uid);
}

@Service @RequiredArgsConstructor
public class OrderService {

    private final OrderRepository orderRepo;

    @Transactional(readOnly = true)           // skips dirty-check flush
    public Page<Order> list(UUID userId, Pageable p) {
        return orderRepo.findByUserId(userId, p);
    }

    @Transactional
    public Order place(OrderRequest req) { /* ... */ }
}
```

## Incorrect example

```java
// @Data walks lazy fields, @ManyToOne defaults EAGER
@Entity @Data
public class Order {
    @ManyToOne                              // EAGER by default — surprise JOIN
    private User user;
    @OneToMany(fetch = FetchType.EAGER)     // over-fetch; breaks pagination
    private List<OrderLine> lines;
}

// JOIN FETCH + Pageable → HHH90003004; result set loaded into heap
@Query("SELECT o FROM Order o JOIN FETCH o.lines")
Page<Order> findAll(Pageable pageable);

// Self-invocation — @Transactional on createInternal() is NOT applied
public void create(OrderRequest req) {
    this.createInternal(req);  // proxy bypassed; no transaction
}
@Transactional
void createInternal(OrderRequest req) { /* ... */ }
```

## Optimistic locking

```java
// Service
try {
    orderService.update(cmd);
} catch (OptimisticLockingFailureException e) {
    throw new ResponseStatusException(HttpStatus.CONFLICT, "Concurrent update — retry");
}
```

## Test: assert query count

```java
// application-test.yml: hibernate.generate_statistics=true
long before = stats.getQueryExecutionCount();
// ... exercise service method ...
assertThat(stats.getQueryExecutionCount() - before).isEqualTo(1);
```

## References

- Pagination + collections deep dive: `claudehut:implement` skill.
- N+1 prevention: `rules/performance/n-plus-one.md`.
