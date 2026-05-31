---
name: lombok
description: Project Lombok conventions for Java/Spring Boot 3.x — safe-annotation matrix, JPA-entity/Jackson/MapStruct interop traps, builder patterns with inheritance, recommended lombok.config. Invoke when editing Java that uses Lombok annotations (@Data, @Builder, @Slf4j) or a lombok.* import.
---

# Lombok — annotation discipline + interop traps

Lombok cuts Java boilerplate but each annotation has trade-offs and a few have hard rules ("never on JPA entities", "needs @Jacksonized for Jackson", "needs @SuperBuilder for inheritance"). This skill encodes the safe matrix.

## Quick start (decision matrix)

| Use case | Annotation set | Notes |
|----------|---------------|-------|
| Spring service / component constructor DI | `@RequiredArgsConstructor` + `final` fields | Idiomatic for Spring Boot 3. No `@Autowired` needed. |
| SLF4J logging | `@Slf4j` | One annotation = `private static final Logger log`. Use `log.info(...)` directly. |
| Immutable DTO / value object | `@Value` (+ `@Builder` + `@Jacksonized` if JSON) | All fields final, class final, no setters. |
| Mutable POJO (non-entity) | `@Data` OR `@Getter @Setter @ToString` | Reserve `@Data` for "I genuinely need all five generated methods". |
| **JPA `@Entity`** | `@Getter @Setter @ToString(onlyExplicitlyIncluded=true) @NoArgsConstructor` + manual `equals`/`hashCode` by id or business key | **NEVER** `@Data` or naked `@EqualsAndHashCode`. See `references/jpa-interop.md`. |
| Builder for flat class | `@Builder` (+ `@Builder.Default` per defaulted field) | |
| Builder across inheritance | `@SuperBuilder` on EVERY level of the chain | `@Builder` does not inherit. See `references/builder-patterns.md`. |
| Jackson deserialization via builder | `@Builder` + `@Jacksonized` | Avoids needing a no-args ctor. |
| Null-check generation | `@NonNull` on params/fields | Throws `NullPointerException` with field name. |
| Add manual overload alongside generated method | `@Tolerate` | Lets you keep e.g. a custom `Foo(String csv)` ctor next to `@AllArgsConstructor`. |

## Anti-patterns (reviewer flags these)

1. `@Data` on a JPA `@Entity` — equals/hashCode walk lazy relations → `LazyInitializationException` or N+1; toString prints every association recursively. **Forbidden.**
2. `@Builder` on a subclass without `@SuperBuilder` on the parent — silently drops parent fields. **Forbidden in inheritance.**
3. `@Builder` field with an initializer but no `@Builder.Default` — builder erases the initializer to `null`/`0`. **Always pair them.**
4. `@RequiredArgsConstructor` on a class where some fields are NOT final and NOT `@NonNull` — those fields are NOT in the generated ctor and stay null at construction. Either mark them `final`/`@NonNull` or use `@AllArgsConstructor`.
5. `@Slf4j` on the class plus a hand-rolled `Logger log = LoggerFactory.getLogger(...)` → compile error (duplicate field) or silent shadowing. Pick one.
6. `@Value` on a class with `@OneToMany`/`@ManyToOne` — value objects are immutable but Hibernate needs a mutable lifecycle. Use `@Embeddable` + plain `@Getter @Setter` instead.
7. `@Builder` returning a record — incompatible with record canonical ctor; use record `with` methods or `@RecordBuilder` (third party).
8. Mixing Lombok-generated `toString` with `@OneToMany` (no exclude) — recursion crash. Always `@ToString(onlyExplicitlyIncluded=true)` or `@ToString.Exclude` the relation.

## Spring Boot 3 idioms

- **Constructor injection**: `@RequiredArgsConstructor` + `final` private fields. No `@Autowired`, no setter injection.
- **Configuration properties**: prefer Java `record` over Lombok `@Value` for `@ConfigurationProperties` — Spring binds records natively in Spring Boot 3.x.
- **DTOs / API contracts**: `@Value @Builder @Jacksonized` for immutable DTOs that Jackson must deserialize.
- **MapStruct interop**: enable `lombok-mapstruct-binding` annotation processor — order matters in the `annotationProcessorPaths` block. See `references/mapstruct-jackson-interop.md`.

## lombok.config (drop at project root + each module root if mono-repo)

```ini
# Anchor here; do not inherit from parents.
config.stopBubbling = true

# Mark generated code so JaCoCo / SonarQube ignore it.
lombok.addLombokGeneratedAnnotation = true

# @NonNull throws NPE with field name (matches Spring's NullPointerExceptions).
lombok.nonNull.exceptionType = NullPointerException

# Make experimental features (@SuperBuilder, @Accessors, @FieldDefaults, @ExtensionMethod) warn so reviewers see them.
lombok.experimental.flagUsage = WARNING

# Copy these annotations to generated builder fields (Jackson, Bean Validation).
lombok.copyableAnnotations += com.fasterxml.jackson.annotation.JsonProperty
lombok.copyableAnnotations += jakarta.validation.constraints.NotNull
lombok.copyableAnnotations += jakarta.validation.constraints.NotBlank
lombok.copyableAnnotations += jakarta.validation.constraints.Size
lombok.copyableAnnotations += jakarta.validation.constraints.Email
```

A ready-to-copy version lives at `assets/templates/lombok.config.tmpl`.

## Workflow detail

For per-annotation specifics + working code snippets, load:

- `references/annotations.md` — every common annotation with do/don't.
- `references/jpa-interop.md` — why `@Data` breaks Hibernate + the safe-entity recipe.
- `references/builder-patterns.md` — `@Builder` vs `@SuperBuilder`, `@Builder.Default`, `@Singular`, `@Tolerate`.
- `references/mapstruct-jackson-interop.md` — annotation-processor ordering, `@Jacksonized`, validation passthrough.
- `references/lombok-config.md` — every key worth setting + rationale.

## Hard rules

- Never put `@Data` or naked `@EqualsAndHashCode` on a `@Entity`.
- Always `@Builder.Default` whenever a `@Builder` field has an initializer.
- Always `@SuperBuilder` on every class in a builder hierarchy.
- Always `@Jacksonized` when Jackson must deserialize a `@Builder` type that lacks a no-args ctor.
- Never combine `@Slf4j` with a manual logger field in the same class.
- `@Value` is for value objects; never on Spring `@ConfigurationProperties` or JPA entities.
- Commit a `lombok.config` at project root; without it, defaults change between Lombok minor releases.

## Exit criteria

- [ ] Every Lombok annotation in the diff matches the decision matrix above.
- [ ] No `@Data`/`@EqualsAndHashCode` on entities; entity equals/hashCode reviewed by hand.
- [ ] Every `@Builder` field with an initializer has `@Builder.Default`.
- [ ] Inheritance chains use `@SuperBuilder` end-to-end.
- [ ] Jackson DTOs that use `@Builder` have `@Jacksonized`.
- [ ] `lombok.config` present and contains at minimum `config.stopBubbling=true` + `lombok.addLombokGeneratedAnnotation=true`.
