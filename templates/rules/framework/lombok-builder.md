---
id: rules/framework/lombok-builder
paths:
  - "**/*Dto.java"
  - "**/*Request.java"
  - "**/*Response.java"
  - "**/*Command.java"
  - "**/*Event.java"
  - "**/*Builder*.java"
severity: high
tags: [lombok, builder, jackson, inheritance]
---
<!-- ClaudeHut rule template — generated into .claude/rules/framework/lombok-builder.md by claudehut-init. Reused & enhanced from committed rules/framework/lombok-builder.md. -->

# `@Builder` / `@SuperBuilder` safety

`@Builder` has three foot-guns whose symptoms only appear at runtime: silent default loss, broken inheritance, and Jackson deserialization failure.

## DO

### Builder with defaults

```java
@Builder
public class Job {
    @Builder.Default private long createdMillis = System.currentTimeMillis();
    @Builder.Default private int retries = 3;
    private String type;
}
```

**Every** `@Builder` field with an initializer MUST carry `@Builder.Default`. Without it, the builder leaves the field at the Java default (`null`/`0`/`false`).

### Builder across inheritance

```java
@SuperBuilder @Getter
public abstract class Event {
    private final UUID id;
    private final Instant occurredAt;
}

@SuperBuilder @Getter
public class OrderPlacedEvent extends Event {
    private final String orderNumber;
    private final BigDecimal total;
}
```

`@SuperBuilder` on **every** class in the chain. `@Builder` on a subclass without `@SuperBuilder` on the parent silently drops parent fields.

### Builder for Jackson deserialization

```java
@Value
@Builder
@Jacksonized
public class CreatePaymentRequest {
    String customerId;
    BigDecimal amount;
    String currency;
}
```

`@Jacksonized` wires the generated builder for Jackson — no need for a no-args ctor, no need for `@JsonDeserialize(builder=...)`.

### Singular collections

```java
@Builder
public class Order {
    @Singular private List<OrderLine> orderLines;
}
```

Generates singular `orderLine(item)` + plural `orderLines(coll)` + `clearOrderLines()` methods. The resulting collection is **immutable**.

### Manual overload alongside builder

```java
@Builder
public class TimeRange {
    private Instant start;
    private Instant end;

    public static class TimeRangeBuilder {
        @Tolerate
        public TimeRangeBuilder duration(Duration d) {
            this.end = this.start == null ? null : this.start.plus(d);
            return this;
        }
    }
}
```

`@Tolerate` lets a hand-written method coexist with Lombok-generated builder methods.

## DON'T

```java
// 1. Default lost silently
@Builder
public class Config {
    private int timeout = 30;                  // ← builder zeroes it out
}

// 2. Parent fields invisible to child builder
public class Event {                           // ← no @SuperBuilder
    private UUID id;
}

@Builder
public class OrderEvent extends Event {        // ← @Builder ignores parent
    private String orderNumber;
}

// 3. Jackson can't deserialize
@Value
@Builder                                       // ← needs @Jacksonized
public class CreateOrderRequest {
    String customerId;
}
// → "Cannot construct instance of CreateOrderRequest"

// 4. @Builder on a record
@Builder
public record OrderId(UUID value) {}           // ← incompatible with record canonical ctor
```

## Reviewer checklist

- [ ] Every `@Builder` field with a `=` initializer has `@Builder.Default`.
- [ ] Inheritance hierarchies use `@SuperBuilder` end-to-end.
- [ ] Jackson-deserialized `@Builder` types carry `@Jacksonized`.
- [ ] `@Singular` collections are documented as immutable, or the field uses `@Builder.Default new ArrayList<>()` instead.
- [ ] No `@Builder` on a `record`.
- [ ] No `@Builder` on an `@Entity` (use the JPA-safe pattern instead).

## See also

- Skill `claudehut:implement`.
- `rules/framework/jackson.md` — DTO conventions that complement Lombok builders.
- `rules/framework/mapstruct.md` — mapping to builder targets.
