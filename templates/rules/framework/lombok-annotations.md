---
id: rules/framework/lombok-annotations
paths:
  - "**/*.java"
severity: medium
tags: [lombok, annotations, conventions]
---
<!-- ClaudeHut rule template — generated into .claude/rules/framework/lombok-annotations.md by claudehut-init. Reused & enhanced from committed rules/framework/lombok-annotations.md. -->

# Lombok — annotation conventions

These rules auto-load on every `.java` file. Lombok's classpath presence is detected at build time; if not present, treat rules as no-ops (`@Slf4j` etc. produce compile errors so the case won't arise in practice).

## DO

- Use `@RequiredArgsConstructor` + `final` private fields for Spring component constructor injection. No `@Autowired`.
- Use `@Slf4j` for SLF4J logging (the default facade in Spring Boot 3.x). Use the lowercase `log` reference (`log.info(...)`).
- Use `@Value` for immutable DTOs / value objects. Pair with `@Builder` for fluent construction.
- Use `@Getter @Setter` selectively when only some fields expose accessors.
- Use `@NonNull` on constructor / method parameters that must not be null — generates an NPE with the parameter name.
- Use `@ToString(onlyExplicitlyIncluded = true)` whenever a class has reference fields you don't want serialized into log lines.
- Use `@Tolerate` to keep a hand-written method alongside a Lombok-generated one with the same name.

## DON'T

- Use `@Data` for general-purpose DTOs — it implies the class is intentionally mutable AND defines identity by every field. Prefer `@Value` for immutable, `@Getter @Setter` for mutable-without-identity-semantics.
- Use `@Slf4j` together with a hand-written logger field — duplicate-field compile error or silent shadowing.
- Use `@Accessors(chain = true)` or `@Accessors(fluent = true)` on classes that pass through Jackson default deserialization — fluent setters break the JavaBean contract Jackson relies on.
- Use `@AllArgsConstructor` on Spring beans — pass dependencies through `final` fields + `@RequiredArgsConstructor`.
- Use `@SneakyThrows` to hide checked exceptions. Wrap with a meaningful unchecked exception, OR declare the throws.
- Use `@UtilityClass` for static utilities — a plain `final class WithPrivateCtor` reads more clearly to reviewers.

## lombok.config required

A `lombok.config` MUST exist at project root and contain at least:

```ini
config.stopBubbling = true
lombok.addLombokGeneratedAnnotation = true
```

Without `config.stopBubbling`, behaviour can change when the project is checked out under a parent directory that ships its own `lombok.config`. Without `lombok.addLombokGeneratedAnnotation`, JaCoCo / SonarQube count generated code against coverage / complexity metrics.

The plugin ships a recommended baseline at `skills/lombok/assets/templates/lombok.config.tmpl` — copy it to project root if missing.

## Examples

```java
// DO — Spring component
@Service
@RequiredArgsConstructor
@Slf4j
public class PaymentService {

    private final PaymentRepository repository;
    private final PaymentGateway gateway;

    public Payment capture(@NonNull String paymentId) {
        log.info("capturing payment {}", paymentId);
        // ...
    }
}

// DO — immutable DTO
@Value
@Builder
@Jacksonized
public class PaymentRequest {
    @NotBlank String customerId;
    @Positive BigDecimal amount;
    @NotBlank String currency;
}

// DON'T — mixed concerns + foot-guns
@Data                                       // implies mutable + identity-by-all-fields
@Slf4j
@Accessors(chain = true)                    // breaks Jackson default
public class PaymentRequest { ... }
```

## See also

- Skill `claudehut:implement` — full annotation matrix + Spring/Jackson interop notes.
- `rules/framework/lombok-jpa-safety.md` — Lombok on `@Entity`.
- `rules/framework/lombok-builder.md` — `@Builder` / `@SuperBuilder` patterns.
