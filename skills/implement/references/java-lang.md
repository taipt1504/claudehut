# Modern Java language + mapping conventions — best-practice playbook
<!-- claudehut: preloaded via claudehut:implement; create-time guidance. Researched vs MapStruct /mapstruct/mapstruct + Lombok /projectlombok/lombok (context7); pure-Java topics (records/sealed/pattern-matching, Optional/Stream, null-safety, immutability, exception hierarchy, SLF4J/MDC) from Java 17/21 language knowledge + project rules. -->

**When:** any `*.java` — DTOs/records, mappers, services, general code style.

---

## DO

### Records + sealed (Java 17+)

- Use `record` for all value types: DTOs, events, query params, projections. Auto-generates `equals`, `hashCode`, `toString`, accessors.
- Compact constructor validates and defensive-copies: `public EmailAddress { Objects.requireNonNull(value); }`.
- Use `sealed interface` for closed type hierarchies (sum types). Exhaustive `switch` patterns (Java 21) become compiler-verified.
- Pattern-matching `switch` over `instanceof` chains whenever > 2 subtypes.

### Immutability

- `final` fields in every non-record class. Initialize collections via `List.copyOf(…)`, `Set.copyOf(…)`, `Map.copyOf(…)`.
- Return `List.of()` (never `null`) from collection-returning methods.
- Use `Instant`/`LocalDate`/`ZonedDateTime` — never `Date` or `Calendar`.
- JPA `@Entity` stays mutable internally; expose only DTO records at service boundaries.

### Null safety

- `Objects.requireNonNull(arg, "arg")` at every public method entry point.
- Return `Optional<T>` from finder methods; never return `null` from methods with reference return types.
- Annotate public API with `@Nonnull`/`@Nullable` (`jakarta.annotation`) for IDE + SpotBugs.
- Never use `Optional` as a field, constructor parameter, or collection element.

### Optional + Stream

- Chain `Optional` with `.map`/`.filter`/`.orElseThrow(() -> new NotFoundException(id))` — never `.get()` without `.isPresent()`.
- Use `.toList()` (Java 16+) instead of `.collect(Collectors.toList())`.
- No `.parallelStream()` on collections < 10k elements or with shared state.
- Never mutate external state inside `.forEach`; never use `.peek()` for side effects.

### Exception hierarchy

- All domain exceptions extend a single abstract `DomainException extends RuntimeException` carrying a `code` string.
- Specific subtypes: `NotFoundException`, `DuplicateException`, `BusinessRuleException`.
- Map to `ProblemDetail` (RFC-7807, built-in Spring 6 / Boot 3) in a single `@RestControllerAdvice` (web-layer mapping mechanics are owned by `web.md` — don't duplicate them).
- Log **at origin OR at handler**, never both — prevents duplicate stack traces.
- No `catch (Exception e)` swallowing, no `e.printStackTrace()`, no raw `throw new RuntimeException("…")`.

### Logging + MDC

- `@Slf4j` on every class; reference lowercase `log`. Never hand-write a logger field alongside `@Slf4j`.
- SLF4J placeholder syntax: `log.info("created user {}", id)` — never string concatenation.
- MDC keys `requestId`, `userId`, `tenantId` populated in a servlet `OncePerRequestFilter` (or Reactor Context for WebFlux). Always `MDC.clear()` in `finally`.
- WARN for recoverable failures, ERROR with exception object for unrecoverable, INFO for business events.

### Lombok

- `@RequiredArgsConstructor` + `private final` fields = constructor injection. No `@Autowired`.
- `@Value @Builder @Jacksonized` for immutable, Jackson-deserialisable DTOs/requests.
- `@Builder.Default` on **every** `@Builder` field with an initializer — omitting it silently resets to `null`/`0`/`false`.
- `@SuperBuilder` on every class in an inheritance chain — mixing `@Builder` (child) + no annotation (parent) silently drops parent fields.
- `@ToString(onlyExplicitlyIncluded = true)` on classes with reference fields that must not appear in logs.
- `lombok.config` at project root with `config.stopBubbling = true` and `lombok.addLombokGeneratedAnnotation = true`.

### MapStruct

- `@Mapper(componentModel = "spring", unmappedTargetPolicy = ReportingPolicy.ERROR)` — catches typo'd target field names at compile time.
- Partial-update method: `@MappingTarget` parameter + `@BeanMapping(nullValuePropertyMappingStrategy = NullValuePropertyMappingStrategy.IGNORE)` — skips null source fields, retains existing target values.
- `nullValueCheckStrategy = NullValueCheckStrategy.ALWAYS` on mappers that touch nullable fields.
- Complex post-processing in `@AfterMapping` default methods, not in `@Mapping(expression = "java(…)")`.
- Shared policy across mappers via `@MapperConfig`.
- Build classpath: `lombok-mapstruct-binding` annotation processor **must appear between** Lombok and MapStruct processors, or Lombok-generated accessors are invisible to MapStruct.

## DON'T

- `@Data` on any class — implies mutable identity-by-all-fields; use `@Value` (immutable) or `@Getter @Setter` (selective).
- `@Data` / `@Builder` / `@EqualsAndHashCode` on `@Entity` — breaks Hibernate proxy, causes `LazyInitializationException` and infinite loop in `hashCode`. See `lombok-jpa-safety.md`.
- `@Builder` on a `record` — incompatible with canonical constructor.
- `@AllArgsConstructor` on Spring beans — defeats constructor injection idiom.
- `@SneakyThrows` to hide checked exceptions — wrap meaningfully or declare `throws`.
- `@Accessors(chain = true)` / `@Accessors(fluent = true)` on Jackson-deserialised types — breaks JavaBean contract.
- `unmappedTargetPolicy = ReportingPolicy.IGNORE` — masks typo'd field names at compile time.
- Commit generated mapper implementations (`target/generated-sources/`, `build/generated/`).
- Hand-written field-copy code alongside a `@Mapper` for the same types.
- `Optional` as a field, parameter, or inside a collection.
- Reuse a `Stream` after a terminal operation.
- `instanceof` chains instead of pattern-matching switch when > 2 subtypes.

---

## Correct example

```java
// --- Record DTO (inbound) + sealed result type ---

public record CreateUserRequest(
    @NotBlank @Email @Size(max = 254) String email,
    @NotBlank @Size(min = 2, max = 100) String name
) {}

@JsonInclude(JsonInclude.Include.NON_NULL)
public record UserResponse(String id, String email, String name, Instant createdAt) {}

public sealed interface UserResult permits UserResult.Created, UserResult.Duplicate {}
public record Created(UserResponse user)   implements UserResult {}
public record Duplicate(String email)      implements UserResult {}

// --- MapStruct mapper ---

@Mapper(componentModel = "spring",
        unmappedTargetPolicy = ReportingPolicy.ERROR,
        nullValueCheckStrategy = NullValueCheckStrategy.ALWAYS)
public interface UserMapper {

    @Mapping(target = "id",        ignore = true)
    @Mapping(target = "createdAt", ignore = true)
    User toEntity(CreateUserRequest req);

    UserResponse toResponse(User user);

    @Mapping(target = "id",        ignore = true)
    @Mapping(target = "createdAt", ignore = true)
    @BeanMapping(nullValuePropertyMappingStrategy = NullValuePropertyMappingStrategy.IGNORE)
    void update(UpdateUserRequest req, @MappingTarget User user);
}

// --- Service using Lombok for DI + logging ---

@Service
@RequiredArgsConstructor
@Slf4j
public class UserService {

    private final UserRepository repository;
    private final UserMapper     mapper;

    public UserResponse create(@Nonnull CreateUserRequest req) {
        Objects.requireNonNull(req, "req");
        if (repository.existsByEmail(req.email())) {
            throw new DuplicateException("user", req.email());
        }
        User saved = repository.save(mapper.toEntity(req));
        log.info("created user {}", saved.getId());
        return mapper.toResponse(saved);
    }

    public Optional<UserResponse> findByEmail(@Nonnull String email) {
        Objects.requireNonNull(email, "email");
        return repository.findByEmail(email).map(mapper::toResponse);
    }

    // Pattern-matching switch over sealed result
    public String describe(UserResult result) {
        return switch (result) {
            case Created  c -> "Created: " + c.user().id();
            case Duplicate d -> "Duplicate email: " + d.email();
        };
    }
}

// --- Immutable value object with compact-constructor validation ---

public record EmailAddress(String value) {
    public EmailAddress {
        if (value == null || !value.matches(".+@.+\\..+")) {
            throw new IllegalArgumentException("invalid email: " + value);
        }
        value = value.toLowerCase(Locale.ROOT);
    }
}
```

---

## Anti-pattern

```java
// @Data on entity — Hibernate proxy + infinite hashCode loop
@Data
@Entity
public class User { @Id UUID id; String email; }

// Builder default silently lost — timeout will be 0, not 30
@Builder
public class Config { private int timeout = 30; }

// Parent fields invisible — id/occurredAt never set via builder
public class Event { private UUID id; private Instant occurredAt; }
@Builder
public class OrderEvent extends Event { private String orderNum; }

// unmappedTargetPolicy=IGNORE — typo in "eemail" is invisible until runtime
@Mapper(unmappedTargetPolicy = ReportingPolicy.IGNORE)
public interface UserMapper {
    @Mapping(target = "eemail", source = "email") // silent at compile time
    UserResponse toResponse(User user);
}

// Optional as field — serialisation hell, IDE warnings, never null anyway
public class User { private Optional<String> middleName; }

// Double-logging — two identical stack traces in production logs
try { ... }
catch (Exception e) { log.error("failed", e); throw e; }
```

---

## Gotchas / version notes

- **Annotation processor order (Gradle/Maven)**: `lombok` → `lombok-mapstruct-binding` → `mapstruct-processor`. Wrong order causes `"No property named 'x' exists in source parameter"` at compile time even though the getter exists.
- **`@Builder.Default` and `@SuperBuilder`**: `@Builder.Default` is **not** inherited; every subclass that uses `@SuperBuilder` must repeat `@Builder.Default` on its own fields.
- **`@Jacksonized` scope**: only works with `@Builder` or `@SuperBuilder` — not with `@Value` alone. Boot auto-configures `ParameterNamesModule`, so plain records deserialise via the canonical constructor without `@Jacksonized`.
- **Records and MapStruct**: MapStruct 1.5+ supports records as mapping targets via the canonical constructor. MapStruct generates a builder-less constructor call. Mark all target fields except computed ones with `@Mapping(target = "x", source = "y")` — `unmappedTargetPolicy = ERROR` enforces this.
- **`sealed` + pattern switch exhaustiveness**: Adding a new `permits` subtype without updating all switch sites is a **compile error** — this is the feature, not a bug. Use it to keep handler coverage complete.
- **`List.copyOf` / `Set.copyOf` reject `null` elements** — if the source collection may contain nulls, filter first or use `Collections.unmodifiableList(new ArrayList<>(source))`.
- **`Optional.orElseThrow()` (no-arg, Java 10+)** throws `NoSuchElementException`; prefer the supplier overload `orElseThrow(() -> new NotFoundException(…))` for meaningful error messages.
- **Stream `.toList()` returns an unmodifiable list** (Java 16+) — do not attempt `add`/`remove` on the result. Use `new ArrayList<>(stream.toList())` if mutability is needed.
- **MDC + virtual threads (Java 21)**: MDC is `ThreadLocal`-backed; virtual threads inherit parent MDC snapshot at creation but mutations after fork are not reflected. Use structured-concurrency scope values (`ScopedValue`) or re-populate MDC in the child task.
- **MapStruct 1.6+**: `componentModel = MappingConstants.ComponentModel.SPRING` is the type-safe constant equivalent of the string `"spring"` — either form compiles, but the constant avoids stringly-typed errors.
