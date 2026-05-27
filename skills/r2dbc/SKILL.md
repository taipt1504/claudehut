---
name: r2dbc
description: Reactive R2DBC conventions for Spring Boot 3.x WebFlux stack. Auto-loads when editing `**/*Repository.java` in projects with orm=r2dbc. Covers ReactiveCrudRepository, R2dbcEntityTemplate, reactive transactions, converter setup, Testcontainers integration.
---

# R2DBC

Reactive non-blocking DB access. Pairs with WebFlux.

## Quick start

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
    Mono<Boolean> existsByEmail(String email);

    @Query("SELECT * FROM users WHERE active = true ORDER BY created_at DESC")
    Flux<User> findAllActive();
}
```

Detailed: `references/repository-patterns.md`, `references/reactive-transactions.md`, `references/converters.md`.

## Assets

- `assets/templates/ReactiveRepository.java.tmpl`
- `assets/templates/R2dbcConfig.java.tmpl`

## Hard rules

- NEVER use JPA annotations (`@Entity`, `@JoinColumn`, `@OneToMany`) in R2DBC entities. R2DBC ≠ JPA.
- NEVER fetch related entities via field reference — manual join queries or N+1 via `flatMap`.
- ALWAYS use `TransactionalOperator` or `@Transactional` (reactive variant) for multi-statement transactions.
- USE `R2dbcEntityTemplate` when query DSL is needed beyond repository derivation.
- POOL config: r2dbc-pool with explicit `initial-size`, `max-size`, `acquire-timeout`.

## Exit criteria

- [ ] Entity uses R2DBC `@Table`, `@Id`, `@Column` (not JPA)
- [ ] No JPA-style relations (`@OneToMany`)
- [ ] Transactions via `TransactionalOperator`
- [ ] Connection pool tuned
