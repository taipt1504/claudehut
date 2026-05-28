---
id: rules/framework/lombok-jpa-safety
paths:
  - "**/*Entity.java"
  - "**/entity/**/*.java"
  - "**/domain/**/*.java"
severity: critical
tags: [lombok, jpa, hibernate, entity, safety]
---

# Lombok safety on JPA `@Entity`

`@Data` and a naked `@EqualsAndHashCode` produce broken equals/hashCode/toString for Hibernate-managed entities. The bug appears at runtime (LazyInitializationException, infinite recursion, hash mismatch after persist) and never at compile time — making it the highest-impact Lombok foot-gun.

## DO

```java
@Entity
@Getter
@Setter
@NoArgsConstructor                          // required by Hibernate
@ToString(onlyExplicitlyIncluded = true)    // safe default — opt-in per field
public class Order {

    @Id
    @GeneratedValue
    @ToString.Include
    private Long id;

    @ToString.Include
    private String number;

    @OneToMany(mappedBy = "order")          // NEVER auto-include
    private Set<OrderLine> lines = new HashSet<>();

    @Override
    public boolean equals(Object o) {
        if (this == o) return true;
        if (!(o instanceof Order other)) return false;
        return number != null && number.equals(other.number);   // business key identity
    }

    @Override
    public int hashCode() {
        return getClass().hashCode();       // constant — safe across persist/load/merge
    }
}
```

Alternative (when an immutable UUID business key is set in the constructor):

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
}
```

This is the only Lombok-generated equals/hashCode that is safe on an entity.

## DON'T

```java
@Entity
@Data                                       // ← lazy-load explosion, hash mismatch, toString recursion
public class Order { ... }

@Entity
@Getter @Setter
@EqualsAndHashCode                          // ← walks every field including lazy relations
public class Order { ... }

@Entity
@ToString                                   // ← stack overflow on bidirectional @OneToMany
public class Order {
    @OneToMany(mappedBy = "order")
    private Set<OrderLine> lines;
}
```

## Why

1. **Lazy load explosion**: `entity.hashCode()` inside `Set<Entity>.contains(...)` walks `@OneToMany` collections → `LazyInitializationException` outside the session or N+1 inside it.
2. **Hash mismatch around persist**: id-based hashCode changes after `persist()` flushes a generated id; an entity stored in a HashSet before persist becomes unreachable after.
3. **toString recursion**: bidirectional `Order ↔ OrderLine` `@ToString` chain crashes with StackOverflowError on the first log statement.

## Hibernate's documented contract

- `hashCode()` must be stable across an entity's lifecycle (create → persist → load → detach → merge → remove).
- `equals()` must implement identity, not "deep field equality".
- The simplest correct combo: constant `hashCode()` (via `getClass().hashCode()` or a hash of an immutable business key) plus `equals()` that compares the business key (or id, with explicit null handling).

## Reviewer block-list

- `@Data` on `@Entity` — **CRITICAL block**.
- `@EqualsAndHashCode` (no `onlyExplicitlyIncluded`) on `@Entity` — **CRITICAL block**.
- `@ToString` without `onlyExplicitlyIncluded` on `@Entity` with `@OneToMany`/`@ManyToMany` — **HIGH block**.
- Missing `@NoArgsConstructor` on `@Entity` — **HIGH block** (Hibernate uses reflection to instantiate).
- Lombok-generated equals/hashCode that includes a `@ManyToOne` association — **HIGH block** (lazy load explosion).

## See also

- Skill `claudehut:lombok` `references/jpa-interop.md`.
- `rules/framework/jpa.md` — broader JPA conventions.
