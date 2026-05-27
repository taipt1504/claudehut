# R2DBC Repository Patterns

## Derived queries

```java
public interface UserRepository extends R2dbcRepository<User, UUID> {
    Mono<User> findByEmail(String email);
    Mono<Boolean> existsByEmail(String email);
    Flux<User> findByActiveTrueOrderByCreatedAtDesc();
}
```

## @Query

```java
@Query("SELECT * FROM users WHERE email LIKE :pattern AND active = true")
Flux<User> searchActive(@Param("pattern") String pattern);
```

## R2dbcEntityTemplate for dynamic queries

```java
@Service
@RequiredArgsConstructor
public class UserSearchService {
    private final R2dbcEntityTemplate template;

    public Flux<User> search(SearchCriteria c) {
        Criteria criteria = Criteria.empty();
        if (c.email() != null) criteria = criteria.and("email").like("%" + c.email() + "%");
        if (c.activeOnly()) criteria = criteria.and("active").isTrue();

        return template.select(Query.query(criteria), User.class);
    }
}
```

## DatabaseClient — lowest-level

```java
@Service
@RequiredArgsConstructor
public class ReportService {
    private final DatabaseClient client;

    public Flux<RevenueByDay> revenueByDay(LocalDate from, LocalDate to) {
        return client.sql("""
                SELECT DATE(created_at) AS day, SUM(amount) AS total
                FROM orders WHERE created_at BETWEEN :from AND :to
                GROUP BY DATE(created_at)
                ORDER BY day
            """)
            .bind("from", from)
            .bind("to", to)
            .map(row -> new RevenueByDay(
                row.get("day", LocalDate.class),
                row.get("total", BigDecimal.class)))
            .all();
    }
}
```

## Paging

```java
public Mono<Page<User>> list(int page, int size) {
    return userRepo.findAllBy(PageRequest.of(page, size))
        .collectList()
        .zipWith(userRepo.count())
        .map(t -> new PageImpl<>(t.getT1(), PageRequest.of(page, size), t.getT2()));
}
```

## Bulk operations

```java
public Mono<Integer> markInactiveOlderThan(Duration age) {
    return template.update(
        Query.query(Criteria.where("last_login").lessThan(Instant.now().minus(age))),
        Update.update("active", false),
        User.class);
}
```

## Anti-patterns

- Using `.block()` on Mono returned by repo → see WebFlux anti-patterns.
- Fetching related entities via separate `findById` calls in a `flatMap` loop → N+1.
- Using `@OneToMany` from JPA → not supported in R2DBC, will silently fail.
- Forgetting `@Version` on entities with concurrent writes → lost updates.
