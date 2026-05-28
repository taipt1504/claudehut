# Builder patterns — `@Builder`, `@SuperBuilder`, defaults, singulars, tolerate

## `@Builder` vs `@SuperBuilder`

| | `@Builder` | `@SuperBuilder` |
|---|------------|------------------|
| Inheritance | ignores parent fields | walks the chain |
| Required on parent | no | **yes** (every level) |
| Maturity | stable | experimental (since 1.18.0, stable in practice) |
| Output | `XBuilder` inner class | `XBuilder` + `XBuilderImpl` per level |
| When to pick | flat classes | any class with a non-Object ancestor |

If the class has a `superclass extends Object` and will never have child classes, `@Builder`. Otherwise `@SuperBuilder` on the parent and **every** child you intend to build.

## `@Builder.Default` — the trap

```java
@Builder
public class Job {
    @Builder.Default
    private long createdMillis = System.currentTimeMillis();   // safe

    private String type;                                       // builder.build() leaves type=null
    private int retries = 3;                                   // WRONG — builder ignores the initializer, retries=0
}
```

Rule: any field declaration with a non-default initializer **must** carry `@Builder.Default`. The compiler will not warn.

## `@Singular` — collection fluency

```java
@Builder
public class Order {
    @Singular private List<OrderLine> orderLines;
}

Order o = Order.builder()
    .orderLine(line1)        // singular method
    .orderLine(line2)
    .orderLines(extra)       // bulk add
    .clearOrderLines()       // reset
    .build();
```

- Builds an **immutable** collection (`Collections.unmodifiableList(...)`). If you need a mutable collection, do NOT use `@Singular` — declare the field with a plain `@Builder.Default` initial empty `ArrayList<>()`.
- Explicit singular noun: `@Singular("axis") List<String> axes`. Use it when Lombok's automatic depluralisation gets it wrong.

## `@Builder(toBuilder = true)` — copy-with-modification

```java
@Builder(toBuilder = true)
public record Page(int page, int size, String sort) {}

Page next = current.toBuilder().page(current.page() + 1).build();
```

- Adds a `toBuilder()` instance method seeded with the current values.
- Subtle gotcha: with `@Singular`, `toBuilder` starts from the existing collection contents — adding a new item appends.

## `@Jacksonized` — Jackson deserialization without a no-args ctor

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

Without `@Jacksonized`, Jackson 2.12+ deserialization of a builder-only type needs `@JsonDeserialize(builder = CreatePaymentRequest.CreatePaymentRequestBuilder.class)` + a manual `@JsonPOJOBuilder(buildMethodName = "build", withPrefix = "")` on the builder. `@Jacksonized` generates that wiring.

Combine with `lombok.copyableAnnotations += com.fasterxml.jackson.annotation.JsonProperty` in `lombok.config` so per-field Jackson annotations propagate from the entity field to the generated builder field.

## `@Tolerate` — keeping a manual method alongside generated builder

When you want a generated `@Builder` PLUS a hand-written builder method that takes a different shape:

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

// Usage:
TimeRange.builder().start(Instant.now()).duration(Duration.ofHours(1)).build();
```

Without `@Tolerate`, Lombok would error out on the duplicate method.

## Builder on a record

Don't. Records have a canonical constructor and a `with` pattern via `record-builder` (third-party) or Java 23+ `withFields`. Lombok `@Builder` on a record either silently no-ops or breaks the canonical ctor.

## Builder with inheritance — concrete recipe

```java
@SuperBuilder
@Getter
public abstract class Event {
    private final UUID id;
    private final Instant occurredAt;
}

@SuperBuilder
@Getter
public class OrderPlacedEvent extends Event {
    private final String orderNumber;
    private final BigDecimal total;
}

OrderPlacedEvent e = OrderPlacedEvent.builder()
    .id(UUID.randomUUID())
    .occurredAt(Instant.now())
    .orderNumber("ORD-1")
    .total(new BigDecimal("99.00"))
    .build();
```

`@SuperBuilder` on `Event` lets the child builder see the parent's fields. Removing it from `Event` silently drops `id` and `occurredAt` from `OrderPlacedEvent.builder()`.

## Reviewer checklist

- [ ] Every `@Builder` field with a declaration initializer has `@Builder.Default`.
- [ ] Inheritance chains use `@SuperBuilder` end-to-end.
- [ ] Jackson-deserialised builder types carry `@Jacksonized`.
- [ ] `@Singular` collections are documented as immutable (or the field is explicitly initialised to a mutable collection without `@Singular`).
- [ ] No `@Builder` on a record.
