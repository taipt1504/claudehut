---
id: rules/coding/immutability
applies-to: "**/*.java"
severity: medium
tags: [immutability, records, defensive-copy]
---

# Immutability

## DO

- Use `record` for value types (DTOs, events, params).
- Use `final` for fields in non-record classes.
- Initialize collections in constructor via `List.copyOf(...)`, `Set.copyOf(...)`, `Map.copyOf(...)` (Java 10+).
- Return defensive copies from getters returning collections.
- Use `record` with `Iterable` params: validate + copy in compact constructor.

## DON'T

- Setters on domain entities — use methods that express intent (`user.activate()` not `user.setActive(true)`).
- Mutable `Date`, `Calendar` — use `Instant`, `LocalDate`, `LocalDateTime`, `ZonedDateTime`.
- Public mutable collection fields.
- Return internal collection references — caller can mutate.

## Examples

```java
// GOOD — record
public record UserCreatedEvent(String userId, String email, Instant ts) {}

// GOOD — final fields + defensive copy
public final class Order {
    private final String id;
    private final List<OrderLine> lines;

    public Order(String id, List<OrderLine> lines) {
        this.id = id;
        this.lines = List.copyOf(lines);
    }

    public List<OrderLine> lines() { return lines; }  // immutable, safe to expose
}

// BAD — mutable
public class Order {
    public String id;            // public, mutable
    public Date createdAt;       // mutable Date
    public List<OrderLine> lines; // exposed internal collection
}
```

## When to keep mutable

- JPA `@Entity` — Hibernate requires setters (or `@NoArgsConstructor` + reflection).
- Builder accumulators.
- Performance-critical hot loops (rare).

For JPA entities: mutable internally, expose via DTO record at boundaries.

## Compact constructor for validation

```java
public record EmailAddress(String value) {
    public EmailAddress {
        if (value == null || !value.matches(".+@.+\\..+")) {
            throw new IllegalArgumentException("invalid email: " + value);
        }
    }
}
```
