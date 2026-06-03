# Spring MVC web layer — best-practice playbook
<!-- claudehut: preloaded via claudehut:implement; create-time guidance. Researched vs Spring Boot 3.4 (context7). -->

**When:** `*Controller.java`, request/response DTOs, web config, `@RestControllerAdvice`.

---

## DO

- `@RestController` (not `@Controller`) for JSON APIs.
- `@RequestMapping(produces = APPLICATION_JSON_VALUE)` at class level; explicit HTTP-method annotation (`@GetMapping`, `@PostMapping`, …) per method.
- `@Valid` on every `@RequestBody`; `@Validated` at class level for `@PathVariable`/`@RequestParam` constraints.
- Return a direct DTO when status is always 200; `ResponseEntity<T>` only when status varies per call.
- Use **Java records** for request/response DTOs — immutable, no boilerplate.
- Separate request DTO from domain entity (mass-assignment prevention).
- Centralize all error mapping in one `@RestControllerAdvice` extending `ResponseEntityExceptionHandler`; emit **RFC-7807 `ProblemDetail`**.
- Add `setProperty("errorCode", ...)` to `ProblemDetail` for machine-readable codes.
- Annotate the advice class with `@Slf4j`; log at `WARN` for 4xx, `ERROR` for 5xx — log **once** (not in both service and advice).
- Configure Jackson via `Jackson2ObjectMapperBuilderCustomizer` bean (not a raw `ObjectMapper` bean, which suppresses auto-config).
- `FAIL_ON_UNKNOWN_PROPERTIES = true` for inbound deserialisation; `NON_NULL` on responses.
- `WRITE_DATES_AS_TIMESTAMPS = false` + `JavaTimeModule` → ISO-8601 strings.

## DON'T

- `@RequestBody User entity` — binds attacker-controlled fields (`id`, `role`, `createdAt`).
- `@RequestMapping` without explicit HTTP method — allows ALL verbs.
- Inject `HttpServletRequest` just to read headers — use `@RequestHeader`.
- Throw raw `RuntimeException` or `Exception` out of a controller or service.
- `catch (Exception e)` swallowing or double-logging (service logs + advice logs same trace).
- `ObjectMapper` `@Bean` override unless you own the full config — breaks Boot auto-config.
- `mapper.activateDefaultTyping()` or `@JsonTypeInfo(use = Id.CLASS)` without `@JsonSubTypes` whitelist — RCE vector.
- `Map<String, Object>` or bare `Object` fields in inbound DTOs.
- Validation logic scattered as manual `if (req.x == null)` checks — use Jakarta constraints.
- `@Valid` only at service; skip it in the controller — trust-boundary violation.

---

## Correct example

```java
// --- DTOs ---

@JsonInclude(JsonInclude.Include.NON_NULL)
public record UserResponse(String id, String email, String name, Instant createdAt) {}

public record CreateUserRequest(
    @NotBlank @Email @Size(max = 254) String email,
    @NotBlank @Size(min = 2, max = 100) String name
) {}

// --- Controller ---

@RestController
@RequestMapping(value = "/users", produces = MediaType.APPLICATION_JSON_VALUE)
@RequiredArgsConstructor
@Validated                          // enables constraint annotations on @PathVariable/@RequestParam
public class UserController {

    private final UserService userService;

    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    public UserResponse create(@RequestBody @Valid CreateUserRequest req) {
        return userService.create(req);
    }

    @GetMapping("/{id}")
    public UserResponse get(
        @PathVariable @Pattern(regexp = "^[a-f0-9\\-]{36}$") String id) {
        return userService.get(id);
    }

    @GetMapping
    public Page<UserResponse> list(
        @RequestParam(defaultValue = "0") @Min(0) int page,
        @RequestParam(defaultValue = "20") @Min(1) @Max(100) int size) {
        return userService.list(PageRequest.of(page, size));
    }
}

// --- Global error handler ---

@RestControllerAdvice
@Slf4j
public class GlobalExceptionHandler extends ResponseEntityExceptionHandler {

    /** Bean Validation failure (body) */
    @Override
    protected ResponseEntity<Object> handleMethodArgumentNotValid(
            MethodArgumentNotValidException ex,
            HttpHeaders headers, HttpStatusCode status, WebRequest request) {
        var pd = ProblemDetail.forStatus(HttpStatus.UNPROCESSABLE_ENTITY);
        pd.setType(URI.create("urn:problem:validation-failed"));
        pd.setTitle("Validation failed");
        pd.setProperty("violations", ex.getFieldErrors().stream()
            .map(e -> Map.of("field", e.getField(), "message", e.getDefaultMessage()))
            .toList());
        return ResponseEntity.unprocessableEntity().body(pd);
    }

    /** Constraint violation (@Validated path/query params) */
    @ExceptionHandler(ConstraintViolationException.class)
    public ProblemDetail handleConstraintViolation(ConstraintViolationException ex) {
        var pd = ProblemDetail.forStatus(HttpStatus.BAD_REQUEST);
        pd.setType(URI.create("urn:problem:constraint-violation"));
        pd.setDetail(ex.getMessage());
        return pd;
    }

    @ExceptionHandler(NotFoundException.class)
    public ProblemDetail handleNotFound(NotFoundException ex) {
        var pd = ProblemDetail.forStatus(HttpStatus.NOT_FOUND);
        pd.setType(URI.create("urn:problem:" + ex.code()));
        pd.setDetail(ex.getMessage());
        return pd;
    }

    @ExceptionHandler(DuplicateException.class)
    public ProblemDetail handleDuplicate(DuplicateException ex) {
        var pd = ProblemDetail.forStatus(HttpStatus.CONFLICT);
        pd.setType(URI.create("urn:problem:" + ex.code()));
        pd.setDetail(ex.getMessage());
        return pd;
    }

    @ExceptionHandler(Exception.class)
    public ProblemDetail handleUnexpected(Exception ex, HttpServletRequest req) {
        log.error("Unhandled exception on {} {}", req.getMethod(), req.getRequestURI(), ex);
        var pd = ProblemDetail.forStatus(HttpStatus.INTERNAL_SERVER_ERROR);
        pd.setType(URI.create("urn:problem:internal-error"));
        pd.setDetail("An unexpected error occurred");
        return pd;
    }
}

// --- Jackson config ---

@Configuration
public class JacksonConfig {
    @Bean
    public Jackson2ObjectMapperBuilderCustomizer customizer() {
        return builder -> builder
            .serializationInclusion(JsonInclude.Include.NON_NULL)
            .featuresToEnable(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES)
            .featuresToDisable(SerializationFeature.WRITE_DATES_AS_TIMESTAMPS)
            .modulesToInstall(new JavaTimeModule());
    }
}
```

---

## Anti-pattern

```java
// Mass-assignment: client sends {"id":"x","role":"ADMIN"} and wins
@PostMapping("/users")
public User create(@RequestBody User user) { return repo.save(user); }

// No method constraint → accepts GET, DELETE, PATCH, …
@RequestMapping("/users")
public List<User> list() { return repo.findAll(); }

// Raw ObjectMapper bean — defeats Spring Boot's auto-config (no JavaTimeModule, etc.)
@Bean
public ObjectMapper objectMapper() { return new ObjectMapper(); }

// Double-logging: service throws after logging → advice logs again → 2 identical stack traces
try { ... } catch (Exception e) { log.error("failed", e); throw e; }
```

---

## Gotchas / version notes

- **Spring Boot 3.x uses Jakarta EE 9+ namespaces** — `jakarta.validation.*`, `jakarta.servlet.*`
  (not `javax.*`). Dependencies: `spring-boot-starter-validation` pulls `hibernate-validator`.
- **`ProblemDetail` is built-in since Spring 6 / Boot 3.0** — no extra library needed.
  `ResponseEntityExceptionHandler` already converts standard MVC exceptions to `ProblemDetail`
  when `spring.mvc.problemdetails.enabled=true` (Boot 3.0+); subclass it and set that property
  to avoid re-inventing 404/405/415 handling.
- **`@Validated` vs `@Valid`**: use `@Valid` on `@RequestBody` (triggers bean validation on the
  whole object graph); use `@Validated` on the controller class to activate method-level
  constraint validation for `@PathVariable` / `@RequestParam`.
- **Records as DTOs**: Jackson deserialises records via the canonical constructor when
  `ParameterNamesModule` is on the classpath (Boot auto-configures it). No `@JsonCreator` needed.
- **`ResponseEntityExceptionHandler` absorbs `MethodArgumentNotValidException`**: if your advice
  extends it, override `handleMethodArgumentNotValid` rather than adding a separate
  `@ExceptionHandler(MethodArgumentNotValidException.class)` — otherwise the override never fires.
- **`FAIL_ON_UNKNOWN_PROPERTIES` default changed**: Boot auto-config sets it to `false` by default
  (lenient inbound). Explicitly re-enable to `true` for strict API contracts.
- **`@JsonInclude` placement**: annotate the *response* DTO (omit nulls outbound) but do **not**
  apply `NON_NULL` globally to the `ObjectMapper` if you have nullable `@RequestBody` fields that
  should still fail on unknown properties.
- **File uploads**: validate MIME via magic-byte inspection (`Apache Tika`), not just
  `getContentType()` — that header is client-supplied.
