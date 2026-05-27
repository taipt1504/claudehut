---
id: rules/framework/mapstruct
applies-to: "**/*Mapper.java"
stack-signal: "mapper=mapstruct"
severity: medium
tags: [mapstruct, mapping]
---

# MapStruct Rules

## DO

- `@Mapper(componentModel = "spring")` for Spring DI.
- `unmappedTargetPolicy = ReportingPolicy.ERROR` — catches typos at compile.
- `nullValueCheckStrategy = NullValueCheckStrategy.ALWAYS` for partial-update mappers.
- `@MappingTarget` + `@BeanMapping(nullValuePropertyMappingStrategy = IGNORE)` for in-place updates.
- Add `lombok-mapstruct-binding` to annotation processor classpath when using Lombok.

## DON'T

- Hand-written copy-fields code alongside a `@Mapper` interface for the same types.
- Commit generated mapper impls (`target/generated-sources/`, `build/generated/`).
- Heavy logic in `@Mapping(expression = "java(...)")` — extract to `@AfterMapping`.
- `unmappedTargetPolicy = ReportingPolicy.IGNORE` — masks typos.

## Correct example

```java
@Mapper(componentModel = "spring",
        unmappedTargetPolicy = ReportingPolicy.ERROR,
        nullValueCheckStrategy = NullValueCheckStrategy.ALWAYS)
public interface UserMapper {

    @Mapping(target = "id", ignore = true)
    @Mapping(target = "createdAt", ignore = true)
    User toEntity(CreateUserRequest req);

    UserResponse toResponse(User user);

    @Mapping(target = "id", ignore = true)
    @Mapping(target = "createdAt", ignore = true)
    @BeanMapping(nullValuePropertyMappingStrategy = NullValuePropertyMappingStrategy.IGNORE)
    void update(UpdateUserRequest req, @MappingTarget User user);
}
```

## Incorrect example

```java
// Hand-written alongside @Mapper — duplicate
public class UserMapperManual {
    public User toEntity(CreateUserRequest req) {
        User u = new User();
        u.setEmail(req.email());
        u.setName(req.name());
        return u;
    }
}
```

## References

- See `claudehut:mapstruct` skill for patterns + AfterMapping usage.
- See `claudehut:jackson` for DTO design that pairs with mappers.
