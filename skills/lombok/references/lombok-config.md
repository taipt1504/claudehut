# `lombok.config` — recommended keys with rationale

`lombok.config` lives in source tree (root + each module root for mono-repos). Lombok walks upward from a source file until it finds a config containing `config.stopBubbling = true`. **Always** anchor.

## Minimum project root

```ini
config.stopBubbling = true
lombok.addLombokGeneratedAnnotation = true
lombok.nonNull.exceptionType = NullPointerException
lombok.experimental.flagUsage = WARNING
```

## Every key worth knowing

| Key | Default | Recommended | Why |
|-----|---------|-------------|-----|
| `config.stopBubbling` | `false` | `true` at project root | Anchors here; CI build won't pick up an unexpected `lombok.config` from a parent dir. |
| `lombok.addLombokGeneratedAnnotation` | `false` | `true` | Tags generated code with `@lombok.Generated`. JaCoCo and SonarQube respect this and skip coverage/complexity rules on generated code. |
| `lombok.nonNull.exceptionType` | `NullPointerException` | `NullPointerException` | Matches Spring's typical NPE handling. Alternatives: `IllegalArgumentException`, `Assertion`, `JDK`. |
| `lombok.equalsAndHashCode.callSuper` | `WARN` | `CALL` for inheritance hierarchies, otherwise leave default | Forces an explicit decision instead of a silent default. |
| `lombok.toString.callSuper` | `SKIP` | `SKIP` | Subclasses usually don't want parent's `toString` mixed in. |
| `lombok.anyConstructor.suppressConstructorProperties` | `false` | `true` for libraries published to public Maven | Removes `@ConstructorProperties` from generated constructors — useful only for Java <14 reflection / Bean introspection. |
| `lombok.copyableAnnotations` | (empty) | List Jackson + Jakarta Validation annotations | See `mapstruct-jackson-interop.md`. |
| `lombok.experimental.flagUsage` | `ALLOW` | `WARNING` | Surfaces use of `@SuperBuilder`, `@Accessors`, `@FieldDefaults`, `@ExtensionMethod` so reviewers see them. |
| `lombok.fieldDefaults.defaultPrivate` | `false` | `false` | Reviewers want field modifiers explicit. |
| `lombok.fieldDefaults.defaultFinal` | `false` | `false` | Same reason. |
| `lombok.var.flagUsage` | `ALLOW` | `ERROR` | Java has `var` natively since 10 — disable Lombok's variant. |
| `lombok.val.flagUsage` | `ALLOW` | `WARNING` | Java has `final var` natively — `val` adds a Lombok-specific import for no benefit. |
| `lombok.addNullAnnotations` | `none` | `jakarta`/`javax`/`jsr305` per stack | Adds nullability annotations on generated methods so static analyzers (IntelliJ, NullAway, ErrorProne) can verify call sites. |
| `lombok.log.fieldName` | `log` | `log` | Keep the default — searching for `log.info` finds usages. |
| `lombok.log.fieldIsStatic` | `true` | `true` | One logger per class, not per instance. |
| `lombok.accessors.chain` | `false` | `false` | Fluent setters confuse Jackson default deserialization. Use `@Accessors(chain=true)` per-class if you really need it. |
| `lombok.accessors.fluent` | `false` | `false` | Same reason. |
| `lombok.allArgsConstructor.flagUsage` | `ALLOW` | `WARNING` | `@AllArgsConstructor` is rarely correct; flag for review. |
| `lombok.data.flagUsage` | `ALLOW` | `WARNING` | Catches accidental `@Data` on what should be `@Value` or a JPA entity. |

## Mono-repo (each module root)

```ini
# module-local config — inherits all settings from project root
# but stops further bubbling so a parent monorepo's lombok.config
# can't accidentally turn off this module's policy.
config.stopBubbling = true
```

Modules that need different settings (e.g. a `legacy-tests` module that uses `@Accessors(fluent=true)` heavily) override here.

## Verifying

```bash
# Show which lombok.config will apply to a given source file.
java -jar lombok.jar config -g src/main/java/com/example/Foo.java
```

Use this when a generated method looks different from what you expected — somewhere up the tree a config is overriding the default.

## CI guard

The plugin's `claudehut-reviewer-style` should fail review if:

- No `lombok.config` exists at project root.
- `lombok.addLombokGeneratedAnnotation` is missing or `false` (skews coverage metrics).
- `lombok.experimental.flagUsage` is `ALLOW` while experimental annotations appear in source.
