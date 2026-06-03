---
id: rules/framework/jpa
paths:
  - "**/*Entity.java"
  - "**/*Repository.java"
stack: "orm=jpa"
severity: high
tags: [jpa, hibernate, n+1]
---
<!-- ClaudeHut rule template — generated into .claude/rules/framework/jpa.md by claudehut-init. Reused & enhanced from committed rules/framework/jpa.md. -->


# JPA / Hibernate Rules

## DO

- `FetchType.LAZY` for all collections (`@OneToMany`, `@ManyToMany`).
- `@EntityGraph` or `JOIN FETCH` for queries that need related data.
- `@Version` on entities with concurrent writes (optimistic locking).
- `@Transactional` (Spring) at service layer for write operations.
- Return `Optional<T>` for finders.

## DON'T

- `FetchType.EAGER` on collections.
- Access lazy fields outside `@Transactional` boundary.
- Use entity as `@RequestBody` (mass assignment + serialization issues).
- Multiple `findById` in a loop — batch instead.
- Forget to add index on foreign key columns.

## Correct example

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

    @OneToMany(mappedBy = "user", fetch = FetchType.LAZY)
    @BatchSize(size = 25)
    private Set<Order> orders;

    @Version
    private Long version;
}

@Repository
public interface UserRepository extends JpaRepository<User, UUID> {
    Optional<User> findByEmail(String email);

    @EntityGraph(attributePaths = {"orders"})
    @Query("SELECT u FROM User u WHERE u.id = :id")
    Optional<User> findByIdWithOrders(@Param("id") UUID id);
}
```

## Incorrect example

```java
@Entity
public class User {
    @OneToMany(fetch = FetchType.EAGER)   // ← over-fetch
    private List<Order> orders;
}

// caller
List<User> users = userRepo.findAll();
for (User u : users) u.getOrders().size();  // N+1
```

## References

- See `claudehut:implement` skill.
- N+1 prevention details: `claudehut:implement`.
- `rules/performance/n-plus-one.md`.
