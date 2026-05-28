# Lombok annotations — complete cheat sheet

Every annotation we actually use, with the one decision the reviewer will check.

## Class-level

### `@Data`

Shortcut: `@Getter @Setter @ToString @EqualsAndHashCode @RequiredArgsConstructor`. **Mutable** class.

- DO: short-lived data carriers (test fixtures, mappers' internal staging objects).
- DON'T: JPA entities. DON'T: DTOs you intend to be immutable.

### `@Value`

Shortcut: `@Getter @AllArgsConstructor @ToString @EqualsAndHashCode @FieldDefaults(makeFinal=true, level=PRIVATE)` + `final class`.

- DO: immutable DTOs, value objects.
- Pair with `@Builder` for fluent construction.
- Pair with `@Jacksonized` when Jackson must deserialize.

### `@Builder`

Generates a static `builder()` and an inner `XBuilder` class.

- `@Builder.Default` on every field whose declaration has an initializer; without it, the builder leaves the field at the Java default (`null`/`0`/`false`).
- `@Singular` on collection fields → adds singular `name(item)` + plural `names(coll)` + `clearNames()` methods.
- `toBuilder = true` to produce a `toBuilder()` instance method (copy-with-modification).
- Class-level vs constructor-level vs method-level: prefer class-level unless you need to expose a specific factory shape.

### `@SuperBuilder`

Like `@Builder` but inheritance-aware. **Every** class in the chain must carry `@SuperBuilder`. The generated `builder()` chains across the hierarchy and exposes ancestor fields.

### `@Jacksonized` *(experimental)*

Place alongside `@Builder` (or `@SuperBuilder`) — Lombok wires the builder so Jackson can deserialize without a no-args constructor and without `@JsonDeserialize(builder=...)`.

### `@NoArgsConstructor` / `@RequiredArgsConstructor` / `@AllArgsConstructor`

- `@NoArgsConstructor`: zero-arg constructor. Required by JPA entities (Hibernate's `newInstance`) and by Jackson default deserializer.
- `@RequiredArgsConstructor`: constructor of `final` and `@NonNull` fields. The Spring-DI standard.
- `@AllArgsConstructor`: every field. Useful for `@Value` / test fixtures; rarely the right answer for a Spring bean.

### `@Getter` / `@Setter`

- Field- or class-level. Use class-level for "everything" generation; use field-level when only some fields expose accessors.
- `AccessLevel`: PUBLIC / PROTECTED / PACKAGE / PRIVATE / MODULE / NONE (NONE disables).
- `@Getter(lazy = true)` for memoized expensive computation.

### `@ToString`

- `@ToString(onlyExplicitlyIncluded = true)` plus `@ToString.Include` on fields you want printed. **Mandatory** on JPA entities to avoid recursing through associations.
- `@ToString.Exclude` on a single noisy field.

### `@EqualsAndHashCode`

- `callSuper = true` when subclass should mix in parent state.
- `onlyExplicitlyIncluded = true` + `@EqualsAndHashCode.Include` on the fields that actually define identity. Always required on `@Entity`.

### Logger family

- `@Slf4j` → SLF4J `org.slf4j.Logger log`. Use this 99 % of the time in Spring Boot 3 (SLF4J is the default facade).
- `@Log4j2` → Log4j2 native; only when project explicitly wires Log4j2 as both facade and impl.
- `@CommonsLog` → Apache Commons Logging. Used by Spring Framework internals; almost never the right pick for application code.
- `@Log` → `java.util.logging`. Avoid.
- `@XSlf4j` → SLF4J fluent / extended API.

## Field- and method-level

### `@NonNull`

On a parameter: generates `if (x == null) throw new NullPointerException("x is marked non-null but is null");` at method entry.
On a field: generates the same check in every generated constructor/setter that touches the field.

### `@With`

Generates copy-on-write methods on an immutable class: `withName(String)` returns a new instance with that field changed. Pair with `@Value`.

### `@Synchronized`

Replaces the implicit `synchronized` on `this`/`Class` with a private dedicated lock object. Use when you actually want intrinsic locking; prefer `java.util.concurrent` for new code.

### `@Cleanup`

`@Cleanup InputStream in = ...;` calls `in.close()` in a finally block at the variable's scope exit. Pre-try-with-resources style — prefer `try-with-resources` in Java 11+.

### `@SneakyThrows`

Re-throws checked exceptions without declaring them. **Last resort.** Use only when wrapping in a `RuntimeException` would obscure the cause and the call site cannot reasonably catch.

### `@Tolerate`

Marks a hand-written method to coexist with Lombok-generated methods of the same name. Common use: extra builder method that handles a different input shape.

### `@Accessors` *(experimental)*

- `chain = true` → setters return `this` (fluent).
- `fluent = true` → setter `name(value)` instead of `setName(value)`, getter `name()` instead of `getName()`. **Breaks** standard JavaBean tooling (Jackson default, BeanUtils). Mostly avoid.

## Annotations to avoid in this codebase

- `@Helper` — replaces a local-class pattern; obscure, never needed.
- `@FieldDefaults` — fine in module-private code; we keep field modifiers explicit instead so reviews don't have to think about Lombok.
- `@UtilityClass` — generates a private constructor + makes everything static. Java already has `final class WithPrivateCtor` which a reviewer can see at a glance.
