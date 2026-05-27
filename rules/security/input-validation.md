---
id: rules/security/input-validation
paths:
  - "**/*Controller.java"
  - "**/*Handler.java"
severity: high
tags: [validation, bean-validation, owasp]
---


# Input Validation

## Principle

Validate at every TRUST BOUNDARY:
- HTTP request → controller/handler.
- Kafka event → consumer.
- File upload → service.
- DB-read trusted (within your boundary), but defensive validation for cross-tenant.

## Bean Validation (Jakarta)

```java
public record CreateUserRequest(
    @NotBlank @Email @Size(max = 254) String email,
    @NotBlank @Size(min = 2, max = 100) String name,
    @NotNull @Min(0) @Max(150) Integer age,
    @Pattern(regexp = "^[A-Z]{2}$") String countryCode,
    @Valid AddressRequest address
) {}

public record AddressRequest(
    @NotBlank String street,
    @NotBlank String city,
    @NotBlank @Pattern(regexp = "^\\d{5}$") String zipCode
) {}
```

Trigger via `@Valid`:

```java
@PostMapping
public UserResponse create(@RequestBody @Valid CreateUserRequest req) { ... }
```

## Path & query validation

```java
@RestController
@Validated  // class-level for params
public class UserController {

    @GetMapping("/{id}")
    public UserResponse get(@PathVariable @Pattern(regexp = "^[a-z0-9-]{36}$") String id) { ... }

    @GetMapping
    public PageResponse<UserResponse> list(@RequestParam @Min(0) int page,
                                            @RequestParam @Min(1) @Max(100) int size) { ... }
}
```

## Mass-assignment prevention

```java
// GOOD — explicit Request DTO, only allowed fields bound
public record CreateUserRequest(String email, String name) {}

@PostMapping
public UserResponse create(@RequestBody @Valid CreateUserRequest req) { ... }
```

```java
// BAD — binding directly to Entity
@PostMapping
public User create(@RequestBody User user) { ... }
// Client sends {"id":"x","role":"ADMIN","createdAt":"..."} — overrides everything
```

## File upload validation

```java
@PostMapping("/upload")
public UploadResponse upload(@RequestParam MultipartFile file) {
    if (file.isEmpty()) throw new IllegalArgumentException("file required");
    if (file.getSize() > 10 * 1024 * 1024) throw new IllegalArgumentException("max 10MB");
    String type = file.getContentType();
    if (!Set.of("image/png", "image/jpeg").contains(type))
        throw new IllegalArgumentException("only png/jpeg");
    // Inspect MIME via magic bytes, not just header (header is client-controlled)
    return uploadService.process(file);
}
```

## Validation messages

```java
public record CreateUserRequest(
    @NotBlank(message = "email is required")
    @Email(message = "email must be valid")
    String email
) {}
```

Or use `messages.properties` for i18n.

## Custom validator

```java
@Target({ElementType.FIELD, ElementType.PARAMETER})
@Retention(RetentionPolicy.RUNTIME)
@Constraint(validatedBy = TenantIdValidator.class)
public @interface ValidTenantId {
    String message() default "invalid tenant ID";
    Class<?>[] groups() default {};
    Class<? extends Payload>[] payload() default {};
}

public class TenantIdValidator implements ConstraintValidator<ValidTenantId, String> {
    public boolean isValid(String value, ConstraintValidatorContext ctx) {
        return value != null && value.matches("^[a-z][a-z0-9-]{3,30}$");
    }
}
```

## Cross-field validation

```java
public record DateRange(@NotNull LocalDate start, @NotNull LocalDate end) {
    @AssertTrue(message = "start must be before end")
    public boolean isValid() {
        return start == null || end == null || !start.isAfter(end);
    }
}
```

## Anti-patterns

- Manual `if (req.email() == null)` checks scattered.
- Validating Entity directly bound to request.
- Skipping `@Valid` and "validating in service".
- Catching `ConstraintViolationException` in controller (handle in advice).
- Heavy logic in custom validator (no DB calls).
- Trusting `Content-Type` header for file uploads.
