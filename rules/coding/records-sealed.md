---
id: rules/coding/records-sealed
paths:
  - "**/*.java"
severity: low
tags: [java17, records, sealed, pattern-matching]
---


# Records + Sealed + Pattern Matching (Java 17+)

## record — for value types

```java
public record UserCreatedEvent(String userId, String email, Instant ts) {}
```

Auto-generates: equals, hashCode, toString, accessor methods.

Use when:
- Class is a data carrier (no behavior beyond accessors).
- All fields participate in equality.
- Immutable.

Don't use when:
- Need inheritance (records are final).
- Have lifecycle (@Entity).

## sealed — closed type hierarchy

```java
public sealed interface PaymentResult permits Success, Declined, Pending {}
public record Success(String txId, BigDecimal amount) implements PaymentResult {}
public record Declined(String reason, String code) implements PaymentResult {}
public record Pending(String txId, Duration retryAfter) implements PaymentResult {}
```

Use when:
- Sum type (algebraic data type).
- Exhaustive switch needed.
- Closed set of subclasses by design.

## Pattern matching for switch (Java 21+)

```java
public String describe(PaymentResult r) {
    return switch (r) {
        case Success s    -> "Charged " + s.amount();
        case Declined d   -> "Declined: " + d.reason();
        case Pending p    -> "Retry in " + p.retryAfter();
    };
}
```

Compiler verifies all cases (exhaustive switch).

## When to migrate

| From | To | When |
|------|-----|------|
| Plain DTO class | record | Always (if Java 17+) |
| Interface with hierarchy | sealed | When hierarchy is closed |
| `if-else` on type | pattern match switch | When > 2 types |
| `instanceof` chain | pattern match switch | Same |

## Anti-patterns

- Records with non-data behavior (turn into class).
- Records mutating via reflection.
- `sealed` without permits clause (permits required unless permitted types in same file).
- Pattern match without `default` for non-exhaustive switches (compile fails).
