---
id: rules/framework/jackson
paths:
  - "**/*Dto.java"
  - "**/*ObjectMapper*.java"
  - "**/*Request.java"
  - "**/*Response.java"
severity: high
tags: [jackson, deserialization, polymorphism]
---


# Jackson Rules

## DO

- `@JsonInclude(JsonInclude.Include.NON_NULL)` on response DTOs.
- Register `JavaTimeModule` for `Instant`, `LocalDateTime`, `ZonedDateTime`.
- `WRITE_DATES_AS_TIMESTAMPS = false` — use ISO 8601 strings.
- `FAIL_ON_UNKNOWN_PROPERTIES = true` for strict inbound DTOs.
- `@JsonSubTypes` whitelist when using `@JsonTypeInfo` polymorphism.

## DON'T

- `mapper.enableDefaultTyping()` / `activateDefaultTyping()` — RCE history.
- `@JsonTypeInfo(use = Id.CLASS)` without `@JsonSubTypes` whitelist.
- `Object` field type in DTOs (accepts any JSON shape).
- `Map<String, Object>` field for inbound DTOs.
- `@JsonAnyGetter`/`@JsonAnySetter` without strong reason.

## Correct example

```java
@JsonInclude(JsonInclude.Include.NON_NULL)
public record UserResponse(
    String id,
    String email,
    String name,
    Instant createdAt
) {}

@JsonTypeInfo(use = Id.NAME, property = "type")
@JsonSubTypes({
    @JsonSubTypes.Type(value = OrderCreatedEvent.class, name = "order.created"),
    @JsonSubTypes.Type(value = OrderShippedEvent.class, name = "order.shipped")
})
public abstract class OrderEvent {
    private String type;
}
```

## Incorrect example

```java
ObjectMapper mapper = new ObjectMapper();
mapper.activateDefaultTyping(...);  // ← Critical CVE vector

public class UnsafeDto {
    private Object payload;            // accepts ANY JSON
    @JsonTypeInfo(use = Id.CLASS)      // attacker controls class name
    private Map<String, Object> data;
}
```

## ObjectMapper config bean

```java
@Configuration
public class JacksonConfig {
    @Bean
    public Jackson2ObjectMapperBuilderCustomizer customizer() {
        return builder -> builder
            .serializationInclusion(JsonInclude.Include.NON_NULL)
            .featuresToEnable(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES)
            .featuresToDisable(SerializationFeature.WRITE_DATES_AS_TIMESTAMPS)
            .modulesToInstall(new JavaTimeModule());
    }
}
```

## References

- See `claudehut:jackson` skill.
- Polymorphism safety: `claudehut:jackson/references/polymorphic-deserialization.md`.
- `rules/security/deserialization.md`.
