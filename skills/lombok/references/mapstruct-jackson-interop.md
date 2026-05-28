# Lombok ↔ MapStruct + Jackson interop

The three annotation processors (Lombok, MapStruct, Jackson) run in the same javac phase. The order in `annotationProcessorPaths` matters — Lombok must process first so the bytecode MapStruct reads already contains the generated getters/setters/builders.

## Gradle wiring (Groovy DSL)

```gradle
dependencies {
    compileOnly       'org.projectlombok:lombok:1.18.34'
    annotationProcessor 'org.projectlombok:lombok:1.18.34'

    implementation       'org.mapstruct:mapstruct:1.6.3'
    annotationProcessor  'org.mapstruct:mapstruct-processor:1.6.3'

    // CRITICAL: tells MapStruct to look at Lombok-generated members.
    annotationProcessor  'org.projectlombok:lombok-mapstruct-binding:0.2.0'

    testCompileOnly       'org.projectlombok:lombok:1.18.34'
    testAnnotationProcessor 'org.projectlombok:lombok:1.18.34'
}
```

Without `lombok-mapstruct-binding`, MapStruct generates `Mapper` implementations that compile against the **non-Lombok** view of your source — every `@Data`-generated getter is invisible and you get "Cannot find getter for property X" errors at compile time.

## Maven wiring

```xml
<build>
  <plugins>
    <plugin>
      <artifactId>maven-compiler-plugin</artifactId>
      <configuration>
        <annotationProcessorPaths>
          <path>
            <groupId>org.projectlombok</groupId>
            <artifactId>lombok</artifactId>
            <version>1.18.34</version>
          </path>
          <path>
            <groupId>org.mapstruct</groupId>
            <artifactId>mapstruct-processor</artifactId>
            <version>1.6.3</version>
          </path>
          <path>
            <groupId>org.projectlombok</groupId>
            <artifactId>lombok-mapstruct-binding</artifactId>
            <version>0.2.0</version>
          </path>
        </annotationProcessorPaths>
      </configuration>
    </plugin>
  </plugins>
</build>
```

Order is important: Lombok → MapStruct → binding. Maven runs processors in declaration order; Gradle does the same.

## Mapping to a `@Builder` target

```java
@Mapper(componentModel = "spring", unmappedTargetPolicy = ReportingPolicy.ERROR)
public interface OrderMapper {

    @Mapping(target = "orderLines", source = "lines")
    OrderDto toDto(Order order);
}

@Value
@Builder
@Jacksonized
public class OrderDto {
    String id;
    List<OrderLineDto> orderLines;
}
```

MapStruct detects `@Builder` and emits the builder-based mapper:

```java
// generated
OrderDto.OrderDtoBuilder builder = OrderDto.builder();
builder.id(order.getId());
builder.orderLines(linesToDtoList(order.getLines()));
return builder.build();
```

If MapStruct does NOT find the builder (binding missing, or Lombok ran after MapStruct), it falls back to no-args ctor + setters → and for `@Value` there is no no-args ctor → "Cannot determine type for property". Fix the processor wiring first.

## Validation passthrough

To get `@NotNull` / `@NotBlank` / `@Email` on the builder fields (so Spring `@Valid` works), add to `lombok.config`:

```ini
lombok.copyableAnnotations += jakarta.validation.constraints.NotNull
lombok.copyableAnnotations += jakarta.validation.constraints.NotBlank
lombok.copyableAnnotations += jakarta.validation.constraints.Size
lombok.copyableAnnotations += jakarta.validation.constraints.Email
```

Without these, the constraints sit on the field but disappear from the builder method parameters; Hibernate Validator sees them on the resulting bean but only after `build()` — which means MapStruct mapping that bypasses validation can produce invalid DTOs.

## Jackson ObjectMapper config that pairs with the Lombok DTO style

```java
ObjectMapper om = JsonMapper.builder()
    .addModule(new JavaTimeModule())                      // for Instant, ZonedDateTime, etc.
    .disable(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES)
    .disable(MapperFeature.ACCEPT_CASE_INSENSITIVE_PROPERTIES)
    .serializationInclusion(JsonInclude.Include.NON_NULL)
    .build();
```

With `@Jacksonized @Value @Builder` DTOs, you don't need `@JsonCreator` / `@JsonProperty` annotations on every field — Jackson uses the generated builder.

## Common error messages and their fixes

| Error | Cause | Fix |
|-------|-------|-----|
| `Cannot find getter for property "x"` (MapStruct) | Lombok processor ran after MapStruct, or `lombok-mapstruct-binding` missing | Reorder annotationProcessorPaths; add the binding. |
| `Cannot construct instance of X` (Jackson) | `@Value @Builder` without `@Jacksonized` | Add `@Jacksonized`. |
| `Annotation processor 'lombok.launch.AnnotationProcessorHider$AnnotationProcessor' could not be loaded` | `compileOnly` only — no `annotationProcessor` entry | Add `annotationProcessor 'org.projectlombok:lombok'` to dependencies. |
| Validation constraints not enforced | Constraints not in `lombok.copyableAnnotations` | Add them to `lombok.config`. |
| `Class has no no-args constructor` (Hibernate or Jackson default) | `@Value` on an entity / Jackson without `@Jacksonized` | Use `@Getter @Setter @NoArgsConstructor` for entities; `@Jacksonized` for DTOs. |
