---
name: mapstruct
description: MapStruct mapper conventions for Java. Auto-loads when editing `**/*Mapper.java` files with @Mapper annotation. Covers @Mapping/@MappingTarget/@BeanMapping config, null strategies, Lombok interop, before/after mapping hooks, generated impl review.
---

# MapStruct

Compile-time mapping. Annotation-driven. Avoids hand-written boilerplate.

## Quick start

```java
@Mapper(componentModel = "spring",
        unmappedTargetPolicy = ReportingPolicy.ERROR,
        nullValueCheckStrategy = NullValueCheckStrategy.ALWAYS)
public interface UserMapper {

    @Mapping(source = "name", target = "fullName")
    @Mapping(target = "createdAt", ignore = true)
    User toEntity(CreateUserRequest req);

    UserResponse toResponse(User user);

    @Mapping(target = "id", ignore = true)
    @BeanMapping(nullValuePropertyMappingStrategy = NullValuePropertyMappingStrategy.IGNORE)
    void update(UpdateUserRequest req, @MappingTarget User user);
}
```

Detailed patterns: `references/mapping-patterns.md`, `references/null-strategies.md`, `references/lombok-interop.md`, `references/anti-patterns.md`.

## Assets

- `assets/templates/Mapper.java.tmpl`

## Hard rules

- ALWAYS `componentModel = "spring"` for Spring DI.
- ALWAYS `unmappedTargetPolicy = ReportingPolicy.ERROR` — catches typos at compile.
- USE `nullValueCheckStrategy = NullValueCheckStrategy.ALWAYS` for partial-update mappers.
- USE `@MappingTarget` for in-place updates.
- DO NOT commit generated impl files (`target/generated-sources/` or `build/generated/`) — gitignore.
- USE `@AfterMapping` only for cross-field derivation; keep mappers declarative.

## Lombok interop

Add `lombok-mapstruct-binding` to annotation processor classpath — otherwise mapping silently breaks.

## Exit criteria

- [ ] `componentModel = "spring"` set
- [ ] `unmappedTargetPolicy = ERROR` set
- [ ] Generated impl reviewed (check `target/generated-sources/`)
- [ ] No hand-written copy-fields boilerplate alongside mapper
