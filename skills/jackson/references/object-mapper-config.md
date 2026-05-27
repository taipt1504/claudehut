# ObjectMapper Config

## Spring Boot auto-config

Spring Boot 3.x autoconfigures Jackson with sane defaults:
- `JavaTimeModule` registered (for `Instant`, `LocalDateTime`, etc.)
- `WRITE_DATES_AS_TIMESTAMPS` disabled (ISO 8601 strings)
- `FAIL_ON_UNKNOWN_PROPERTIES` disabled (lenient)

Override via `Jackson2ObjectMapperBuilderCustomizer`:

```java
@Configuration
public class JacksonConfig {

    @Bean
    public Jackson2ObjectMapperBuilderCustomizer customizer() {
        return builder -> builder
            .serializationInclusion(JsonInclude.Include.NON_NULL)
            .featuresToEnable(
                DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES,
                SerializationFeature.WRITE_BIGDECIMAL_AS_PLAIN
            )
            .featuresToDisable(
                SerializationFeature.WRITE_DATES_AS_TIMESTAMPS,
                SerializationFeature.FAIL_ON_EMPTY_BEANS
            )
            .modulesToInstall(new JavaTimeModule());
    }
}
```

## Recommended features

### Enable

| Feature | Why |
|---------|-----|
| `FAIL_ON_UNKNOWN_PROPERTIES` | Catch DTO drift early |
| `WRITE_BIGDECIMAL_AS_PLAIN` | Avoid scientific notation for money |
| `INCLUDE_NON_NULL` | Skip null fields in response |

### Disable

| Feature | Why |
|---------|-----|
| `WRITE_DATES_AS_TIMESTAMPS` | Use ISO 8601 strings, not epoch ms |
| `FAIL_ON_EMPTY_BEANS` | Allow empty records/classes |
| `defaultTyping` | CRITICAL — never enable (RCE vector) |

## Date/time handling

```java
.modulesToInstall(new JavaTimeModule())
```

This module handles:
- `Instant` ↔ `"2025-05-27T10:00:00Z"`
- `LocalDateTime` ↔ `"2025-05-27T10:00:00"`
- `LocalDate` ↔ `"2025-05-27"`
- `ZonedDateTime` ↔ `"2025-05-27T10:00:00+07:00[Asia/Ho_Chi_Minh]"`

Without it: `Instant` serialized as `{"epochSecond": 1716800400, "nano": 0}`.

## Naming strategy

For snake_case API:

```java
.propertyNamingStrategy(PropertyNamingStrategies.SNAKE_CASE)
```

Inbound `user_email` → field `userEmail`. Outbound `userEmail` → JSON `user_email`.

## Visibility

By default, Jackson uses getters. To use private fields directly:

```java
.visibility(PropertyAccessor.FIELD, JsonAutoDetect.Visibility.ANY)
.visibility(PropertyAccessor.GETTER, JsonAutoDetect.Visibility.NONE)
```

Useful for records (no setters needed) or strict immutability.

## Multiple ObjectMappers

When you need different config per use case (e.g., one for inbound API, one for outbound to a partner with snake_case):

```java
@Bean("apiMapper")
@Primary
public ObjectMapper apiMapper(Jackson2ObjectMapperBuilder builder) {
    return builder.build();
}

@Bean("partnerMapper")
public ObjectMapper partnerMapper() {
    return new ObjectMapper()
        .registerModule(new JavaTimeModule())
        .setPropertyNamingStrategy(PropertyNamingStrategies.SNAKE_CASE);
}
```

Inject by name: `@Qualifier("partnerMapper") ObjectMapper m`.

## Anti-patterns

- `new ObjectMapper()` without config → no JavaTimeModule, no nulls policy, default typing risk
- `.enableDefaultTyping()` / `.activateDefaultTyping()` → CRITICAL RCE vector
- `FAIL_ON_UNKNOWN_PROPERTIES = false` for inbound API → silent acceptance of typo'd fields
- Different mapper config in tests vs prod → bugs only surface in prod
- Mixing field/getter visibility unpredictably → confusion
