# JPA / Hibernate persistence (companion to `claudehut:implement`)

<!-- claudehut: preloaded via claudehut:implement; create-time guidance. Researched vs Hibernate 6 / Spring Data JPA (context7). -->

**When:** `*Entity.java`, `*Repository.java`, JPA mappings/queries.

---

## DO

- Declare `FetchType.LAZY` **explicitly** on every association — `@OneToMany`/`@ManyToMany` default LAZY, but `@ManyToOne`/`@OneToOne` default **EAGER**; always be explicit.
- Use `@EntityGraph(attributePaths = {...})` or `JOIN FETCH` for queries that need related data.
- Apply `@BatchSize(size = 25–50)` (or `hibernate.default_batch_fetch_size`) as a safety net for lazy collections.
- Use `@Version` (type `Long` or `Integer`) on entities that can be concurrently written.
- Place `@Transactional` at the **service layer** for writes; read-only service methods use `@Transactional(readOnly = true)`.
- Return `Optional<T>` from finders; never return `null` from a repository method.
- Use DTO / interface projections for read-only list endpoints — avoids managed-entity overhead and serialization hazards.
- Add an index on every FK column (`@Index` in `@Table` or the migration DDL).
- Implement `equals`/`hashCode` via a **business key** (or an immutable UUID set at construction), not `@Id` (which changes on persist). Keep `hashCode()` constant (`getClass().hashCode()`) so entities survive in `HashSet` through persist → load → merge.
- Use `@NoArgsConstructor` (or an explicit no-arg constructor) — Hibernate requires it for proxying.
- Prefer `@ToString(onlyExplicitlyIncluded = true)` and opt-in per field; never include `@OneToMany`/`@ManyToMany` in `toString`.

## DON'T

- `@Data` on `@Entity` — generates `equals`/`hashCode` that walks every field including lazy relations → `LazyInitializationException`, hash mismatch around persist, `StackOverflowError` on bidirectional `toString`.
- `@EqualsAndHashCode` without `onlyExplicitlyIncluded = true` on an entity — same explosion.
- `@ToString` without `onlyExplicitlyIncluded` when a bidirectional `@OneToMany` exists.
- `FetchType.EAGER` on collections — forces a join on every load, breaks `Pageable` pagination.
- `JOIN FETCH` two collections in one query — cartesian product; fetch one, batch the other.
- `JOIN FETCH` a collection with `Pageable` — Hibernate paginates **in memory** and emits a warning; use `@EntityGraph` or fetch-IDs-then-entities instead.
- Access a lazy field outside a `@Transactional` boundary → `LazyInitializationException`.
- Use an entity as `@RequestBody` or `@ResponseBody` — mass-assignment and serialization hazards.
- Multiple `findById` calls in a loop — batch via `findAllById(ids)` or a bulk query.
- Forget `@Version` when two threads can write the same row.

---

## Correct example

```java
// Entity — safe Lombok + business-key equals/hashCode
@Entity
@Table(name = "orders", indexes = @Index(columnList = "user_id"))
@Getter
@Setter
@NoArgsConstructor
@ToString(onlyExplicitlyIncluded = true)
public class Order {

    @Id
    @GeneratedValue(strategy = GenerationType.UUID)
    @ToString.Include
    private UUID id;

    @Column(nullable = false, unique = true)
    @ToString.Include
    private String number;               // business key

    @ManyToOne(fetch = FetchType.LAZY)   // explicit — default would be EAGER
    @JoinColumn(name = "user_id")
    private User user;

    @OneToMany(mappedBy = "order", fetch = FetchType.LAZY)
    @BatchSize(size = 25)
    private Set<OrderLine> lines = new HashSet<>();

    @Version
    private Long version;

    @Override
    public boolean equals(Object o) {
        if (this == o) return true;
        if (!(o instanceof Order other)) return false;
        return number != null && number.equals(other.number);
    }

    @Override
    public int hashCode() {
        return getClass().hashCode();   // stable across the entity lifecycle
    }
}

// Repository — EntityGraph for joined load; plain finder for scalar paths
public interface OrderRepository extends JpaRepository<Order, UUID> {

    Optional<Order> findByNumber(String number);

    // Avoid JOIN FETCH + Pageable on a collection — use @EntityGraph instead
    @EntityGraph(attributePaths = {"lines"})
    Page<Order> findByUserId(UUID userId, Pageable pageable);

    // For non-paginated bulk: JOIN FETCH is fine
    @Query("SELECT o FROM Order o JOIN FETCH o.lines WHERE o.user.id = :uid")
    List<Order> findByUserIdWithLines(@Param("uid") UUID uid);
}

// DTO projection — read-only list endpoint, no managed entity
public interface OrderSummary {
    UUID getId();
    String getNumber();
    BigDecimal getTotal();
}

// Service — owns transactional boundary
@Service
@RequiredArgsConstructor
public class OrderService {

    private final OrderRepository orderRepo;

    @Transactional
    public Order place(OrderRequest req) { /* ... */ }

    @Transactional(readOnly = true)
    public List<OrderSummary> listByUser(UUID userId) {
        return orderRepo.findSummariesByUserId(userId);
    }
}
```

## Anti-pattern

```java
// @Data walks all fields including lazy collections — NEVER on @Entity
@Entity
@Data                                       // ← LazyInitializationException, hashCode explosion
public class Order {

    @ManyToOne                              // ← default EAGER (surprise extra join on every load)
    private User user;

    @OneToMany(fetch = FetchType.EAGER)     // ← over-fetch; breaks pagination
    private List<OrderLine> lines;
}

// N+1 in a service — no fetch hint
@Transactional(readOnly = true)
public List<String> lineNumbers(UUID userId) {
    List<Order> orders = orderRepo.findByUserId(userId);  // 1 query
    return orders.stream()
        .flatMap(o -> o.getLines().stream())              // N queries — one per order
        .map(OrderLine::getNumber)
        .toList();
}

// JOIN FETCH + Pageable — Hibernate paginates in memory
@Query("SELECT o FROM Order o JOIN FETCH o.lines")
Page<Order> findAll(Pageable pageable);     // ← HHH90003004 warning; wrong results on large sets
```

---

## Gotchas / version notes

**Hibernate 6 (Spring Boot 3.x)**
- `FetchType.LAZY` on `@OneToOne` with a shared PK (`@MapsId`) is unreliable — Hibernate may eagerly load it. Use `@ManyToOne` or a query-level fetch instead.
- `GenerationType.UUID` is a first-class strategy in Hibernate 6 (no custom generator needed); generates a UUID v7-style value by default in 6.2+.
- `spring.jpa.open-in-view=true` is the Boot default — **disable it** (`false`) so lazy-load bugs surface at the service boundary, not silently in the view layer.
- `hibernate.default_batch_fetch_size=25` (or higher) as a global fallback is cheap insurance; set it in `application.yml`.

**Pagination + collections**
- `JOIN FETCH` a collection → Hibernate 6 issues `HHH90003004` and paginates in memory. Fix: fetch the page of IDs first, then fetch entities with `@EntityGraph` by those IDs.

**Optimistic locking**
- `@Version` on `Long`/`Integer` — Hibernate throws `OptimisticLockException` on stale writes; map to HTTP 409 at the service/controller boundary.
- `Long` version wraps around at `Long.MAX_VALUE` — a non-issue in practice but use `Integer` if the entity row is short-lived and high-churn.

**equals / hashCode lifecycle**
- An entity in a `HashSet` before `persist()` uses `getClass().hashCode()` (stable). Id-based `hashCode()` would change after flush, making the entity unreachable in the set.
- Never include a `@ManyToOne` field in Lombok-generated `equals`/`hashCode` — triggers lazy load on every comparison.

**Detection tooling**
```yaml
# application-test.yml
spring:
  jpa:
    show-sql: true
    properties:
      hibernate.generate_statistics: true
```
```java
// Assert query count in integration tests
long before = sessionFactory.getStatistics().getQueryExecutionCount();
// ... exercise code ...
assertThat(sessionFactory.getStatistics().getQueryExecutionCount() - before).isEqualTo(1);
```
Or use `datasource-proxy` / `ttddyy/datasource-proxy` for SQL-level counting in tests.
