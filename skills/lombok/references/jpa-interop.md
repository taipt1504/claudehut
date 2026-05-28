# Lombok ↔ JPA / Hibernate — the safe entity recipe

`@Data` looks tempting on an `@Entity` but it generates a `equals`/`hashCode` that walks every field — including lazy-loaded associations. Three concrete failures the reviewer will catch:

1. **Lazy load explosion**: `entity.hashCode()` inside a `Set<Entity>` membership check triggers `getCollection()` on a `@OneToMany`, which throws `LazyInitializationException` outside the session or runs an unintended N+1 query inside it.
2. **Hash mismatch around persist**: the generated `hashCode` includes `id`. Before `persist()`, `id` is `null`; after the flush, JPA writes the generated id. A bean stored in a `HashSet` before persist becomes unreachable after. Detached / merged entities behave equally erratically.
3. **`toString` recursion**: `@Data` includes `@ToString` over every field. A bidirectional `Order ↔ OrderLine` association produces stack overflow on the first `log.info("loaded order {}", order)`.

## The recipe

```java
import jakarta.persistence.Entity;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.Id;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;
import lombok.ToString;

@Entity
@Getter
@Setter
@NoArgsConstructor                    // required by Hibernate.
@ToString(onlyExplicitlyIncluded = true)  // safest default — opt-in per field.
public class Order {

    @Id
    @GeneratedValue
    @ToString.Include
    private Long id;

    @ToString.Include
    private String number;

    @OneToMany(mappedBy = "order")    // NEVER auto-include in toString
    private Set<OrderLine> lines = new HashSet<>();

    // Identity by business key (preferred) OR by id with null-tolerance.
    @Override
    public boolean equals(Object o) {
        if (this == o) return true;
        if (!(o instanceof Order other)) return false;
        // Business-key identity: order.number is the natural key.
        return number != null && number.equals(other.number);
    }

    @Override
    public int hashCode() {
        // Constant within an Order instance regardless of id state.
        return getClass().hashCode();
    }
}
```

### Why constant `hashCode` is correct

Hibernate-recommended pattern: an entity's `hashCode` must NOT change across persist/load/merge. Using `getClass().hashCode()` (or `Objects.hashCode(stableBusinessKey)`) keeps every instance hashable into a `HashSet` from creation through the entity's lifecycle.

`equals` then carries the actual identity (id once flushed, or a unique business key). The combination of "constant hashCode + equals by stable key" is documented in Vlad Mihalcea's Hibernate guide and the JBoss Hibernate ORM docs.

## What about `@EqualsAndHashCode(onlyExplicitlyIncluded = true)`?

It works for fields that never change — e.g. an entity with a `UUID` business key set in the constructor. In that case:

```java
@Entity
@Getter @Setter @NoArgsConstructor
@ToString(onlyExplicitlyIncluded = true)
@EqualsAndHashCode(onlyExplicitlyIncluded = true)
public class Invoice {

    @Id
    @ToString.Include
    @EqualsAndHashCode.Include
    private UUID uuid = UUID.randomUUID();

    private BigDecimal amount;
}
```

This is the only Lombok-generated equals/hashCode that is safe on an entity, and only when the included key is set BEFORE the first `equals/hashCode` call and never mutated.

## Inheritance / `@MappedSuperclass`

- `@SuperBuilder` is fine here (builders).
- Manual `equals`/`hashCode` lives on the most derived concrete entity, not on the `@MappedSuperclass`.
- If you must Lombok-generate, add `callSuper = false` and define identity at each concrete level — the base class id is not enough when subclasses share a table per concrete strategy.

## Lazy loading + `toString`

Default Lombok `toString` will eagerly resolve `@ManyToOne` and walk `@OneToMany` collections. Even the "include only `id`" approach is unsafe if the `id` field is a lazy proxy. Use `@ToString(onlyExplicitlyIncluded = true)` and explicitly add only primitives / `String` / `UUID` / business-key fields.

## Reviewer checklist

- [ ] No `@Data` / `@Value` on any `@Entity`.
- [ ] `@NoArgsConstructor` present (Hibernate requirement).
- [ ] `@ToString(onlyExplicitlyIncluded = true)` + `@ToString.Include` only on safe fields.
- [ ] `equals`/`hashCode` written by hand (constant hashCode + key-based equals) OR `@EqualsAndHashCode(onlyExplicitlyIncluded = true)` on an immutable business key.
- [ ] No `@OneToMany`/`@ManyToMany` field appears in any generated method.
