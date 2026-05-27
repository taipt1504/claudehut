# Jackson Mixins

## Why mixins

Add Jackson annotations to a class WITHOUT modifying that class. Useful when:

- Class is from a library you can't modify.
- You want to keep domain class free of serialization annotations.
- Different APIs need different serialization of the same class.

## Pattern

```java
// Domain class — no Jackson annotations
public class User {
    private UUID id;
    private String email;
    private String passwordHash;
    // getters...
}

// Mixin — annotation-only abstract class
public abstract class UserApiMixin {
    @JsonIgnore
    abstract String getPasswordHash();

    @JsonProperty("user_id")
    abstract UUID getId();
}
```

Register:

```java
@Configuration
public class JacksonConfig {
    @Bean
    public Jackson2ObjectMapperBuilderCustomizer customizer() {
        return builder -> builder
            .mixIn(User.class, UserApiMixin.class);
    }
}
```

Output:

```json
{ "user_id": "...", "email": "..." }
```

Note: `passwordHash` excluded (via `@JsonIgnore`).

## Multiple mixins per class

Use different `ObjectMapper` instances:

```java
@Bean("publicApiMapper")
public ObjectMapper publicMapper() {
    return new ObjectMapper().addMixIn(User.class, PublicMixin.class);
}

@Bean("adminApiMapper")
public ObjectMapper adminMapper() {
    return new ObjectMapper().addMixIn(User.class, AdminMixin.class);
}
```

## Mixin with @JsonCreator

```java
public abstract class UserMixin {
    @JsonCreator
    UserMixin(@JsonProperty("user_id") UUID id,
              @JsonProperty("email") String email) {}
}
```

Useful for libraries with package-private constructors.

## When NOT to use mixins

- You control the class → annotate directly (simpler).
- One-off field rename → use `@JsonProperty` directly when possible.
- Records → records don't support mixins well; modify record or wrap in DTO.

## Anti-patterns

- Mixin for every domain class → noise; if you control class, annotate it
- Mixin with logic (concrete methods) → confuses Jackson
- Mixin not registered → silently ignored, no error
- Multiple mixins competing on same class → last-registered wins, hard to debug
