# Fetch Strategies — N+1 Prevention

## The N+1 problem

```java
// BAD
List<User> users = userRepo.findAll();
for (User u : users) {
    log.info("orders: {}", u.getOrders().size());  // ← N additional queries
}
```

Each `u.getOrders()` triggers a separate SELECT. With N users → N+1 total queries.

## Fix 1 — JOIN FETCH

```java
@Query("SELECT u FROM User u LEFT JOIN FETCH u.orders")
List<User> findAllWithOrders();
```

Single query loads users + orders in one round trip.

Limitation: cannot paginate `JOIN FETCH` with collections (returns duplicate users). Use `@EntityGraph` instead.

## Fix 2 — @EntityGraph

```java
@EntityGraph(attributePaths = {"orders", "address"})
List<User> findAll();
```

Spring Data builds the fetch plan. Multiple paths possible.

For paginated:

```java
@EntityGraph(attributePaths = {"orders"}, type = EntityGraph.EntityGraphType.LOAD)
Page<User> findAll(Pageable pageable);
```

## Fix 3 — Batch size

```java
@OneToMany(mappedBy = "user", fetch = FetchType.LAZY)
@BatchSize(size = 10)
private Set<Order> orders;
```

Or globally in `application.yml`:

```yaml
spring:
  jpa:
    properties:
      hibernate.default_batch_fetch_size: 50
```

Hibernate batches N lazy loads into `IN (...)` query.

## Fetch types

| Type | When |
|------|------|
| `LAZY` | Default for collections. Loads on access (within transaction). |
| `EAGER` | Loads immediately. Use sparingly — easy to over-fetch. Default for `@ManyToOne`/`@OneToOne`. |

Best practice:
- Collections → always `LAZY`.
- `@ManyToOne`/`@OneToOne` → `LAZY` if you sometimes don't need the relation; default `EAGER` is OK if always used.

## Read-only with projection

If you don't need full entity, use projection (skips dirty checking, faster):

```java
public interface UserSummary {
    UUID getId();
    String getName();
    String getEmail();
}

@Query("SELECT u FROM User u WHERE u.active = true")
List<UserSummary> findAllSummaries();
```

## DTO projection

```java
@Query("""
    SELECT new com.x.UserDto(u.id, u.name, u.email)
    FROM User u WHERE u.active = true
""")
List<UserDto> findAllAsDto();
```

## Detection

Hibernate's `org.hibernate.stat.Statistics`:

```java
@Component
public class JpaQueryCounter {
    @PersistenceContext EntityManager em;

    public long getQueryCount() {
        return em.getEntityManagerFactory()
            .unwrap(SessionFactoryImpl.class)
            .getStatistics()
            .getQueryExecutionCount();
    }
}
```

In tests:

```java
@Test
void shouldNotN1_whenLoadingUsersWithOrders() {
    var before = counter.getQueryCount();
    var users = userRepo.findAllWithOrders();
    users.forEach(u -> u.getOrders().size());  // access
    var after = counter.getQueryCount();
    assertThat(after - before).isEqualTo(1);
}
```
