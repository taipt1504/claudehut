# JPA Projection

## Why project

When you don't need the full entity, projection reduces:
- Memory (smaller row size)
- Query time (fewer columns)
- Hibernate overhead (no dirty-check, no proxy)

## Interface projection

```java
public interface UserSummary {
    UUID getId();
    String getName();
    String getEmail();
}

@Repository
public interface UserRepository extends JpaRepository<User, UUID> {
    List<UserSummary> findByActiveTrue();
}
```

Spring auto-creates proxy implementing the interface. Field names must match entity property names.

## Class-based DTO projection

```java
public record UserDto(UUID id, String name, String email) {}

@Query("""
    SELECT new com.x.UserDto(u.id, u.name, u.email)
    FROM User u WHERE u.active = true
""")
List<UserDto> findActiveDto();
```

Constructor expression in JPQL. Record works in Hibernate 6+.

## Nested interface projection

```java
public interface UserWithOrgSummary {
    UUID getId();
    String getName();
    OrgInfo getOrganization();

    interface OrgInfo {
        UUID getId();
        String getName();
    }
}
```

Hibernate fetches associated entities lazily as needed.

## Dynamic projection

```java
@Repository
public interface UserRepository extends JpaRepository<User, UUID> {
    <T> List<T> findByActiveTrue(Class<T> type);
}

// Caller decides projection
List<UserDto> dtos = repo.findByActiveTrue(UserDto.class);
List<UserSummary> sums = repo.findByActiveTrue(UserSummary.class);
List<User> full = repo.findByActiveTrue(User.class);
```

## When NOT to project

- Need to modify the data → return Entity, not DTO.
- Caller iterates and triggers lazy loads → defeats projection.
- Projection becomes "almost the entity" → just return Entity.

## Open vs closed projection

**Closed projection** (getters match entity fields directly):

```java
public interface UserSummary {
    String getName();  // maps to User.name
}
```

Hibernate emits SELECT name FROM users (efficient).

**Open projection** (uses SpEL):

```java
public interface UserDisplay {
    @Value("#{target.firstName + ' ' + target.lastName}")
    String getDisplayName();
}
```

Hibernate emits SELECT * (whole row) then applies SpEL. Less efficient.

## Performance comparison

| Approach | Memory | Query | Hibernate work |
|----------|--------|-------|----------------|
| Entity (full) | 100% | SELECT * | dirty-check, proxy |
| Interface projection | ~30% | SELECT cols | minimal |
| DTO projection | ~30% | SELECT cols | minimal |
| Open projection | 100% | SELECT * | SpEL eval |

For read-heavy lists: prefer closed interface or DTO projection.

## Anti-patterns

- Returning Entity for read-only API responses → triggers lazy loads + extra queries
- Open projection on hot path → wastes the projection benefit
- Projection interface with `getOrders()` triggering lazy collection → N+1
- Projection + @Cacheable returning Entity → cache stores half-loaded entity
