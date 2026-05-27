# MapStruct + Lombok Interop

## Required: lombok-mapstruct-binding

Without this binding, MapStruct runs BEFORE Lombok generates accessors → mapper impl has no setters/getters to call → silent broken impl.

### Gradle

```kotlin
dependencies {
    compileOnly("org.projectlombok:lombok:1.18.32")
    annotationProcessor("org.projectlombok:lombok:1.18.32")
    annotationProcessor("org.mapstruct:mapstruct-processor:1.5.5.Final")
    annotationProcessor("org.projectlombok:lombok-mapstruct-binding:0.2.0")
}
```

### Maven

```xml
<plugin>
  <artifactId>maven-compiler-plugin</artifactId>
  <configuration>
    <annotationProcessorPaths>
      <path>
        <groupId>org.projectlombok</groupId>
        <artifactId>lombok</artifactId>
        <version>1.18.32</version>
      </path>
      <path>
        <groupId>org.mapstruct</groupId>
        <artifactId>mapstruct-processor</artifactId>
        <version>1.5.5.Final</version>
      </path>
      <path>
        <groupId>org.projectlombok</groupId>
        <artifactId>lombok-mapstruct-binding</artifactId>
        <version>0.2.0</version>
      </path>
    </annotationProcessorPaths>
  </configuration>
</plugin>
```

## Order matters

Annotation processors run in declaration order. Lombok must come BEFORE MapStruct processor.

## Common breakage signals

- Generated mapper impl with empty body.
- Generated impl has `return null;` only.
- Compile-time warning "Unmapped target property: ..." despite explicit `@Mapping`.

All signal missing binding.

## With records (Java 17+)

Records don't need Lombok — they auto-generate accessors. MapStruct handles records natively. Skip Lombok entirely for new record-based DTOs.

```java
public record CreateUserRequest(String email, String name) {}
public record UserResponse(String id, String email, String name) {}

@Mapper(componentModel = "spring", unmappedTargetPolicy = ReportingPolicy.ERROR)
public interface UserMapper {
    User toEntity(CreateUserRequest req);
    UserResponse toResponse(User user);
}
```
