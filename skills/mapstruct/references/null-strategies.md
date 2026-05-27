# MapStruct Null Strategies

## NullValueCheckStrategy

| Value | Behavior |
|-------|----------|
| `ON_IMPLICIT_CONVERSION` (default) | Only checks null when type conversion happens |
| `ALWAYS` | Checks null for every source property |

For **partial update mappers** (use `@MappingTarget`), use `ALWAYS` to avoid overwriting target with null:

```java
@Mapper(componentModel = "spring",
        unmappedTargetPolicy = ReportingPolicy.ERROR,
        nullValueCheckStrategy = NullValueCheckStrategy.ALWAYS)
public interface UserMapper {
    @BeanMapping(nullValuePropertyMappingStrategy = NullValuePropertyMappingStrategy.IGNORE)
    void update(UpdateUserRequest req, @MappingTarget User user);
}
```

## NullValuePropertyMappingStrategy

| Value | Behavior |
|-------|----------|
| `SET_TO_NULL` (default) | Target field becomes null |
| `IGNORE` | Target field preserved |
| `SET_TO_DEFAULT` | Target field set to default (0, "", empty list) |

For PATCH semantics → `IGNORE`. For PUT semantics → `SET_TO_NULL`.

## NullValueMappingStrategy (for whole source)

| Value | Behavior |
|-------|----------|
| `RETURN_NULL` (default) | Mapper returns null if source is null |
| `RETURN_DEFAULT` | Mapper returns empty target |

Most APIs prefer explicit null-check + Optional in caller over `RETURN_DEFAULT`.

## Recommended combos

| Use case | Settings |
|----------|----------|
| Create entity from request | default settings (return null if req null at caller) |
| PATCH partial update | `nullValueCheckStrategy=ALWAYS` + `nullValuePropertyMappingStrategy=IGNORE` |
| PUT full update | `nullValuePropertyMappingStrategy=SET_TO_NULL` (default) |
| Response DTO from entity | default |
