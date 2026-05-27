---
name: jpa-hibernate
description: JPA + Hibernate conventions for Spring Boot 3.x servlet stack. Auto-loads when editing `**/*Repository.java`, `**/*Entity.java` in projects with orm=jpa. Covers @Entity mapping, fetch strategies (N+1 prevention), @Transactional semantics, JPQL/Criteria, projection patterns.
---

# JPA + Hibernate

## Quick start

```java
@Entity
@Table(name = "users")
@Getter @Setter @NoArgsConstructor @AllArgsConstructor
public class User {
    @Id
    @GeneratedValue(strategy = GenerationType.UUID)
    private UUID id;

    @Column(nullable = false, unique = true)
    private String email;

    @Column(nullable = false)
    private String name;

    @Version
    private Long version;
}

@Repository
public interface UserRepository extends JpaRepository<User, UUID> {
    Optional<User> findByEmail(String email);
    boolean existsByEmail(String email);

    @EntityGraph(attributePaths = {"orders"})
    @Query("SELECT u FROM User u WHERE u.id = :id")
    Optional<User> findByIdWithOrders(@Param("id") UUID id);
}
```

Detailed patterns: `references/entity-mapping.md`, `references/fetch-strategies.md`, `references/transactional-semantics.md`, `references/projection.md`.

## Assets

- `assets/templates/Entity.java.tmpl`
- `assets/templates/Repository.java.tmpl`

## Hard rules

- ALWAYS `FetchType.LAZY` for collections (`@OneToMany`, `@ManyToMany`).
- ALWAYS use `JOIN FETCH` or `@EntityGraph` in queries that need collection eagerly.
- NEVER access lazy collection outside `@Transactional` boundary (LazyInitializationException).
- ALWAYS `@Version` for optimistic locking on entities with concurrent writes.
- USE `Optional<T>` for `findOne/findById` returns, never `null`.

## Exit criteria

- [ ] Entity has `@Version` field if updates expected concurrently
- [ ] Collections lazy; eager loading via `@EntityGraph` or `JOIN FETCH`
- [ ] Service layer has `@Transactional` for write operations
- [ ] No N+1 in repository methods
