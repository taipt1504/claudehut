# Validation

## DTO with Bean Validation

```java
public record CreateUserRequest(
    @NotBlank @Email @Size(max = 254) String email,
    @NotBlank @Size(min = 2, max = 100) String name,
    @NotNull @Min(0) @Max(150) Integer age,
    @Pattern(regexp = "^[A-Z]{2}$") String countryCode
) {}
```

## Trigger via @Valid

```java
@PostMapping
public ResponseEntity<UserResponse> create(@RequestBody @Valid CreateUserRequest req) {
    return ResponseEntity.status(CREATED).body(service.create(req));
}
```

`@Valid` triggers Bean Validation. Failures throw `MethodArgumentNotValidException` → handled by `@ControllerAdvice`.

## Validate path/query params

```java
@RestController
@Validated  // class-level for params
public class UserController {

    @GetMapping("/{id}")
    public UserResponse get(@PathVariable @Pattern(regexp = "^[a-z0-9-]{36}$") String id) {
        return service.get(id);
    }

    @GetMapping
    public PageResponse<UserResponse> list(@RequestParam @Min(0) int page,
                                            @RequestParam @Min(1) @Max(100) int size) {
        return service.list(PageRequest.of(page, size));
    }
}
```

`ConstraintViolationException` is thrown — handle separately.

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
    @Override
    public boolean isValid(String value, ConstraintValidatorContext ctx) {
        return value != null && value.matches("^[a-z][a-z0-9-]{3,30}$");
    }
}
```

## Validation groups

```java
public interface OnCreate {}
public interface OnUpdate {}

public record UserRequest(
    @Null(groups = OnCreate.class) @NotNull(groups = OnUpdate.class) String id,
    @NotBlank @Email String email
) {}

// Controller
@PostMapping
public UserResponse create(@RequestBody @Validated(OnCreate.class) UserRequest req) { ... }

@PutMapping("/{id}")
public UserResponse update(@PathVariable String id, @RequestBody @Validated(OnUpdate.class) UserRequest req) { ... }
```

## Anti-patterns

- Manual `if (req.email() == null)` checks scattered in service → use annotations.
- Validating Entity directly bound to request → mass assignment risk. Use DTO.
- Skipping `@Valid` and using ad-hoc validation → inconsistent errors.
- Catching `ConstraintViolationException` in controller → handle in advice.
- Heavy logic inside custom validator → keep validators fast (no DB calls).

## Cross-field validation

```java
public record DateRange(
    @NotNull LocalDate start,
    @NotNull LocalDate end
) {
    @AssertTrue(message = "start must be before end")
    public boolean isValidRange() {
        return start == null || end == null || !start.isAfter(end);
    }
}
```
