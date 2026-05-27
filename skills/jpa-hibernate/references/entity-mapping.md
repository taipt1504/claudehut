# JPA Entity Mapping

## Basic entity

```java
@Entity
@Table(name = "users")
@Getter @Setter @NoArgsConstructor @AllArgsConstructor
public class User {

    @Id
    @GeneratedValue(strategy = GenerationType.UUID)
    private UUID id;

    @Column(nullable = false, unique = true, length = 254)
    private String email;

    @Column(nullable = false, length = 100)
    private String name;

    @Column(name = "created_at", nullable = false, updatable = false)
    private Instant createdAt;

    @Column(name = "updated_at", nullable = false)
    private Instant updatedAt;

    @Version
    private Long version;

    @PrePersist
    void onCreate() {
        Instant now = Instant.now();
        this.createdAt = now;
        this.updatedAt = now;
    }

    @PreUpdate
    void onUpdate() {
        this.updatedAt = Instant.now();
    }
}
```

## ID generation strategies

| Strategy | When |
|----------|------|
| `UUID` | Distributed systems, no central counter |
| `IDENTITY` | DB auto-increment (Postgres serial, MySQL AUTO_INCREMENT) |
| `SEQUENCE` | Postgres/Oracle sequences (more control than IDENTITY) |
| `TABLE` | Avoid — slow, just for legacy |
| Assigned (no `@GeneratedValue`) | When ID is natural (vd email) |

Modern services: UUID. Legacy migrations: IDENTITY.

## Relationships

### Many-to-One (owner side)

```java
@ManyToOne(fetch = FetchType.LAZY)
@JoinColumn(name = "organization_id", nullable = false)
private Organization organization;
```

### One-to-Many (inverse side)

```java
@OneToMany(mappedBy = "user", fetch = FetchType.LAZY, cascade = CascadeType.ALL, orphanRemoval = true)
@BatchSize(size = 25)
private Set<Order> orders = new HashSet<>();
```

Use `Set` not `List` (avoid Hibernate bag warning for many-to-many).

### Many-to-Many

```java
@ManyToMany
@JoinTable(
    name = "user_roles",
    joinColumns = @JoinColumn(name = "user_id"),
    inverseJoinColumns = @JoinColumn(name = "role_id")
)
private Set<Role> roles = new HashSet<>();
```

Or, more controllable: model the join table as an entity with composite key.

## Embedded value object

```java
@Embeddable
public record Address(
    String street,
    String city,
    @Column(length = 20) String zipCode
) {}

@Entity
public class User {
    @Embedded
    private Address address;
}
```

Stored as columns in `users` table.

## Enum

```java
@Enumerated(EnumType.STRING)
@Column(length = 20)
private OrderStatus status;
```

ALWAYS `STRING`, never `ORDINAL` (ordinal breaks when enum order changes).

## Audit fields (Spring Data JPA)

```java
@EntityListeners(AuditingEntityListener.class)
@Entity
public class User {
    @CreatedDate
    private Instant createdAt;
    @LastModifiedDate
    private Instant updatedAt;
    @CreatedBy
    private String createdBy;
}

@Configuration
@EnableJpaAuditing
public class JpaConfig { }
```

## Anti-patterns

- `FetchType.EAGER` on collections → over-fetch + N+1 risk
- `CascadeType.ALL` on `@ManyToOne` → deletes parent on child delete
- Mutable `@Id` field → identity confusion
- `@Enumerated(EnumType.ORDINAL)` → fragile
- `@OneToMany` without `mappedBy` → JPA creates extra join table
- Missing `@Version` on concurrently-updated entity → lost updates
- Forgetting `@NoArgsConstructor` → Hibernate cannot instantiate
- Public fields (no `@Getter`/`@Setter`) → Hibernate proxy issues
