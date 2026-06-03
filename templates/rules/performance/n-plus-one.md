---
id: rules/performance/n-plus-one
paths:
  - "**/*Repository.java"
  - "**/*Service.java"
severity: high
tags: [n+1, jpa, r2dbc, performance]
---
<!-- ClaudeHut rule template — generated into .claude/rules/performance/n-plus-one.md by claudehut-init. Reused & enhanced from committed rules/performance/n-plus-one.md. -->


# N+1 Query Prevention

## Symptom

```java
List<User> users = userRepo.findAll();        // 1 query
for (User u : users) {
    int orderCount = u.getOrders().size();    // 1 query × N users = N more queries
}
// Total: N+1 queries
```

Latency: O(N) instead of O(1).

## Fix — JPA

### JOIN FETCH

```java
@Query("SELECT u FROM User u LEFT JOIN FETCH u.orders")
List<User> findAllWithOrders();
```

Single query.

Limitation: cannot use with `Pageable` (returns duplicate users when joining collection).

### @EntityGraph

```java
@EntityGraph(attributePaths = {"orders", "address"})
List<User> findAll();
```

Or:

```java
@EntityGraph(attributePaths = {"orders"}, type = EntityGraph.EntityGraphType.LOAD)
Page<User> findAll(Pageable pageable);
```

### Batch fetch

Globally:

```yaml
spring:
  jpa:
    properties:
      hibernate.default_batch_fetch_size: 50
```

Or per-relation:

```java
@OneToMany(mappedBy = "user", fetch = FetchType.LAZY)
@BatchSize(size = 25)
private Set<Order> orders;
```

Hibernate groups N lazy loads into `WHERE user_id IN (?, ?, ?, ...)`.

## Fix — R2DBC

No automatic JOIN. Manual approach:

```java
public Flux<UserWithOrders> findAllWithOrders() {
    return userRepo.findAll()
        .collectList()
        .flatMapMany(users -> {
            Set<UUID> userIds = users.stream().map(User::id).collect(toSet());
            return orderRepo.findByUserIdIn(userIds)
                .collectMultimap(Order::userId)
                .map(orderMap -> users.stream()
                    .map(u -> new UserWithOrders(u, orderMap.getOrDefault(u.id(), List.of())))
                    .toList())
                .flatMapIterable(Function.identity());
        });
}
```

2 queries instead of N+1.

## Detection

Hibernate Statistics:

```java
@Component
public class JpaQueryCounter {
    @PersistenceContext EntityManager em;

    public long queryCount() {
        return em.getEntityManagerFactory().unwrap(SessionFactoryImpl.class)
            .getStatistics().getQueryExecutionCount();
    }
}
```

Test:

```java
@Test
void shouldNotN1_whenLoadingUsersWithOrders() {
    long before = counter.queryCount();
    List<User> users = userRepo.findAllWithOrders();
    users.forEach(u -> u.getOrders().size());
    long after = counter.queryCount();
    assertThat(after - before).isEqualTo(1);  // not 1 + N
}
```

Test framework: hibernate-stats-jpa-counter, datasource-proxy, etc.

## P5n4j (sniffer)

```xml
<dependency>
    <groupId>net.ttddyy</groupId>
    <artifactId>datasource-proxy</artifactId>
</dependency>
```

Logs every SQL — easy to spot N+1 in test output.

## Anti-patterns

- `.findAll()` then iterate calling lazy collection.
- `Stream.map(u -> u.getOrders().getFirst())` without fetch hint.
- Multiple `findById` calls in a loop — refactor to batch.
- Returning Entity with lazy relations to controller (serialization triggers lazy → N+1 + LazyInitializationException).

## Rule of thumb

If your query returns N rows and you're going to iterate each — predict EXACTLY which fields you'll touch. Fetch them all in the query.
