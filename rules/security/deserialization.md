---
id: rules/security/deserialization
paths:
  - "**/*.java"
severity: critical
tags: [jackson, deserialization, rce]
---


# Safe Deserialization

## Why critical

Insecure deserialization → remote code execution (RCE). History: Jackson, Hibernate, Apache Commons Collections, Apache Struts CVEs all rooted in unsafe deserialization.

## Jackson — disable default typing

```java
// NEVER
ObjectMapper mapper = new ObjectMapper();
mapper.enableDefaultTyping(...);     // ← Critical
mapper.activateDefaultTyping(...);   // ← Critical
```

These allow JSON `"@class": "com.foo.SomeClass"` to instantiate ARBITRARY classes.

## Jackson — safe polymorphism

```java
@JsonTypeInfo(use = Id.NAME, property = "type")
@JsonSubTypes({
    @JsonSubTypes.Type(value = OrderCreated.class, name = "order.created"),
    @JsonSubTypes.Type(value = OrderShipped.class, name = "order.shipped")
})
public abstract class OrderEvent { ... }
```

`use = Id.NAME` with explicit `@JsonSubTypes` whitelist. Unknown `type` → exception.

## Jackson — strict deserialization

```java
@Bean
public Jackson2ObjectMapperBuilderCustomizer customizer() {
    return builder -> builder
        .featuresToEnable(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES)
        .featuresToDisable(MapperFeature.ALLOW_FINAL_FIELDS_AS_MUTATORS);
}
```

## Java built-in serialization — avoid

`java.io.Serializable` has well-known RCE vectors. Don't use for cross-process or untrusted input. If unavoidable:

- Use `ObjectInputFilter` to allowlist classes.
- Better: switch to JSON / Protobuf / Avro.

## XML — disable external entities (XXE)

```java
DocumentBuilderFactory factory = DocumentBuilderFactory.newInstance();
factory.setFeature("http://apache.org/xml/features/disallow-doctype-decl", true);
factory.setFeature("http://xml.org/sax/features/external-general-entities", false);
factory.setFeature("http://xml.org/sax/features/external-parameter-entities", false);
factory.setXIncludeAware(false);
factory.setExpandEntityReferences(false);
```

## YAML — SafeConstructor

```java
// snakeyaml
Yaml yaml = new Yaml(new SafeConstructor());  // Safe — only standard types
Map<String, Object> data = yaml.load(input);

// BAD
Yaml yaml = new Yaml();  // Default Constructor → can instantiate arbitrary classes
```

## Detection (Phase 5 reviewer-security)

Regex flagged Critical:

```regex
\.enableDefaultTyping\(
\.activateDefaultTyping\(
new ObjectInputStream\(.*\)  # bare deserialization without filter
DocumentBuilderFactory\.newInstance\(\)  # check next lines for setFeature
new Yaml\(\)  # without SafeConstructor
```

## Allow-list pattern (custom deserializer)

```java
public class StrictEventDeserializer extends JsonDeserializer<Event> {
    private static final Map<String, Class<? extends Event>> REGISTRY = Map.of(
        "order.created", OrderCreatedEvent.class,
        "order.shipped", OrderShippedEvent.class
    );

    @Override
    public Event deserialize(JsonParser p, DeserializationContext ctx) throws IOException {
        JsonNode node = p.getCodec().readTree(p);
        String type = node.get("type").asText();
        Class<? extends Event> target = REGISTRY.get(type);
        if (target == null) throw new JsonMappingException(p, "Unknown event type: " + type);
        return p.getCodec().treeToValue(node, target);
    }
}
```

## Anti-patterns

- Trusting `"@class"` field from external JSON.
- Calling `Class.forName(userInput)` anywhere.
- ObjectInputStream without filter.
- Unrestricted YAML / XML parsing.
- Putting `Object` field type in deserialized DTO.
- Caching ObjectMapper with default typing enabled "for legacy support".
