---
id: rules/framework/r2dbc
paths:
  - "**/*Repository.java"
stack: "orm=r2dbc"
severity: high
tags: [r2dbc, reactive, repository]
---


# R2DBC Rules

## DO

- Use R2DBC annotations (`@Table`, `@Id`, `@Column`) — NOT JPA.
- Use `record` for entities (no setters needed).
- Use `TransactionalOperator` for multi-statement transactions.
- Tune r2dbc-pool sizing.
- Manual joins for related data (no `@OneToMany`).

## DON'T

- Use JPA annotations (`@Entity`, `@OneToMany`, `@JoinColumn`).
- `.block()` in reactive chain.
- Use `Mono.fromCallable + subscribeOn(boundedElastic)` for R2DBC — it's already reactive.
- Use JPA-style cascade.

## Correct example

```java
@Table("users")
public record User(
    @Id UUID id,
    String email,
    String name,
    @CreatedDate Instant createdAt,
    @LastModifiedDate Instant updatedAt,
    @Version Long version
) {}

@Repository
public interface UserRepository extends R2dbcRepository<User, UUID> {
    Mono<User> findByEmail(String email);

    @Query("SELECT * FROM users WHERE active = true ORDER BY created_at DESC LIMIT :limit")
    Flux<User> findActive(@Param("limit") int limit);
}
```

## Transaction example

```java
@Service
@RequiredArgsConstructor
public class OrderService {
    private final OrderRepository orderRepo;
    private final InventoryRepository inventoryRepo;
    private final TransactionalOperator tx;

    public Mono<Order> place(OrderRequest req) {
        return tx.transactional(
            inventoryRepo.reserve(req.itemId(), req.qty())
                .then(orderRepo.save(new Order(req)))
        );
    }
}
```

## Incorrect example

```java
@Table("users")
public class User {
    @OneToMany  // ← JPA annotation, not supported in R2DBC
    private Set<Order> orders;
}
```

## References

- See `claudehut:r2dbc` skill.
- Reactive transactions: `claudehut:r2dbc/references/reactive-transactions.md`.
