---
name: jackson
description: Jackson serialization/deserialization conventions for Spring Boot 3.x. Auto-loads when editing `**/*Dto.java`, `**/*Request.java`, `**/*Response.java`, `**/ObjectMapper*.java`, `**/JsonConfig*.java`. Covers ObjectMapper config, polymorphic deserialization (subtype whitelist), JavaTimeModule, mixins, mass-assignment prevention.
---

# Jackson

JSON serialization. Spring Boot autoconfigures sensibly; this skill covers when to override.

## Quick start

```java
@Configuration
public class ObjectMapperConfig {

    @Bean
    public Jackson2ObjectMapperBuilderCustomizer jacksonCustomizer() {
        return builder -> builder
            .serializationInclusion(JsonInclude.Include.NON_NULL)
            .featuresToDisable(SerializationFeature.WRITE_DATES_AS_TIMESTAMPS)
            .featuresToEnable(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES)
            .modulesToInstall(new JavaTimeModule());
    }
}
```

Detailed: `references/object-mapper-config.md`, `references/polymorphic-deserialization.md`, `references/time-handling.md`, `references/mixins.md`, `references/anti-patterns.md`.

## Assets

- `assets/templates/ObjectMapperConfig.java.tmpl`
- `assets/templates/Dto.java.tmpl`

## Hard rules

- NEVER `mapper.enableDefaultTyping()` / `activateDefaultTyping()` — RCE history (CVE-2017-7525).
- ALWAYS `@JsonSubTypes` whitelist when using `@JsonTypeInfo(use=...)`.
- ALWAYS register `JavaTimeModule` for `Instant`/`LocalDateTime`/etc.
- USE `@JsonInclude(JsonInclude.Include.NON_NULL)` for response DTOs.
- USE strict DTOs (`*Request`) instead of `@RequestBody Entity` (mass assignment).
- DO NOT use `Object` field types in DTOs.

## Exit criteria

- [ ] No default typing enabled anywhere
- [ ] All polymorphic types have explicit subtype whitelist
- [ ] JavaTimeModule registered
- [ ] Response DTOs skip nulls
- [ ] No `Object` or `Map<String, Object>` fields in inbound DTOs without explicit reason
