# Polymorphic Deserialization — Safely

## The risk

```java
// NEVER DO THIS
mapper.enableDefaultTyping(...);
// or
mapper.activateDefaultTyping(...);
```

Allows attacker to specify class names in JSON. CVE-2017-7525 was the start; many gadgets followed.

## Safe pattern — explicit whitelist

```java
@JsonTypeInfo(
    use = JsonTypeInfo.Id.NAME,           // ← logical name, not class name
    property = "type",
    visible = true                          // include type in deserialized obj
)
@JsonSubTypes({
    @JsonSubTypes.Type(value = OrderCreated.class, name = "order.created"),
    @JsonSubTypes.Type(value = OrderShipped.class, name = "order.shipped"),
    @JsonSubTypes.Type(value = OrderCanceled.class, name = "order.canceled")
})
public abstract class OrderEvent {
    private String type;
    private String orderId;
    private Instant ts;
}

public class OrderCreated extends OrderEvent {
    private BigDecimal amount;
}
```

JSON in:

```json
{ "type": "order.created", "orderId": "o1", "amount": 100.00 }
```

Jackson deserializes to `OrderCreated`. Unknown `type` → exception, not arbitrary class.

## With defaultImpl

```java
@JsonTypeInfo(use = Id.NAME, property = "type", defaultImpl = UnknownEvent.class)
```

Unknown subtype falls back to `UnknownEvent` instead of failing.

## Inheritance with sealed types

```java
@JsonTypeInfo(use = Id.NAME, property = "type")
@JsonSubTypes({
    @JsonSubTypes.Type(value = SuccessResponse.class, name = "success"),
    @JsonSubTypes.Type(value = ErrorResponse.class, name = "error")
})
public sealed interface ApiResponse permits SuccessResponse, ErrorResponse {}

public record SuccessResponse(String type, Object data) implements ApiResponse {}
public record ErrorResponse(String type, String code, String message) implements ApiResponse {}
```

## Custom deserializer with allow-list

If you can't use annotation-based:

```java
public class StrictTypeDeserializer extends JsonDeserializer<Event> {
    private final Map<String, Class<? extends Event>> registry = Map.of(
        "order.created", OrderCreated.class,
        "order.shipped", OrderShipped.class
    );

    @Override
    public Event deserialize(JsonParser p, DeserializationContext ctx) throws IOException {
        JsonNode node = p.getCodec().readTree(p);
        String type = node.get("type").asText();
        Class<? extends Event> targetClass = registry.get(type);
        if (targetClass == null) {
            throw new JsonMappingException(p, "Unknown event type: " + type);
        }
        return p.getCodec().treeToValue(node, targetClass);
    }
}
```

## Validation hooks

- `@Valid` triggers Bean Validation on deserialized objects.
- For polymorphic types, validate subtypes individually.

## Detection regex (reviewer-security)

```regex
\.enableDefaultTyping\(
\.activateDefaultTyping\(
ObjectMapper\(\)\.enableDefaultTyping
```

If any match → Critical finding.

## When polymorphism isn't needed

Don't over-engineer. If you have ONE response shape, use a plain record. Polymorphism is needed only when the JSON shape genuinely varies by `type`.
