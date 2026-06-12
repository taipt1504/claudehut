---
id: rules/framework/spring-mvc
paths:
  - "**/*Controller.java"
  - "**/*ControllerAdvice.java"
  - "**/*ExceptionHandler.java"
stack: "web=mvc"
severity: high
tags: [spring-mvc, rest, controller, problem-detail, validation]
---
<!-- ClaudeHut rule template — generated into .claude/rules/framework/spring-mvc.md by claudehut-init. Reused & enhanced from committed rules/framework/spring-mvc.md. -->

# Spring MVC Controller Rules

## Quick reference

| Concern | Correct | Wrong |
|---|---|---|
| Controller type | `@RestController` | `@Controller` (requires `@ResponseBody` per method) |
| Request body binding | `@RequestBody @Valid CreateUserRequest req` | `@RequestBody User entity` (mass assignment) |
| Error contract | `ProblemDetail` (RFC 7807/9457) | Raw `Map`, plain string, or custom envelope |
| Exception handler base | extend `ResponseEntityExceptionHandler` | standalone `@ExceptionHandler` that re-covers standard exceptions |
| Validation miss | `@Valid` on `@RequestBody`; `@Validated` on class for path/query | Skip → client-controlled input reaches service |
| Pagination | `Pageable` param + `Page<T>` return | unbounded `List<T>` — OOM under load |
| Content type | explicit `produces`/`consumes` | omit → Spring infers; mismatches silently return 406/415 |
| DTO type | Java record or separate POJO | `@Entity` or `Map<String, Object>` |

## DO

- `@RestController` + class-level `@RequestMapping(produces = APPLICATION_JSON_VALUE)`.
- `@Valid` on `@RequestBody`; `@Validated` at class level for `@PathVariable`/`@RequestParam`.
- Return direct DTO when always 200; `ResponseEntity<T>` only when status varies per call.
- Single `@RestControllerAdvice` extending `ResponseEntityExceptionHandler`; emit `ProblemDetail`.
- Set `spring.mvc.problemdetails.enabled=true` — auto-converts 404/405/415 without override.
- Map `MethodArgumentNotValidException` by *overriding* `handleMethodArgumentNotValid` (not a
  parallel `@ExceptionHandler`) — the parent catches it first; a sibling handler never fires.
- Paginate: accept `Pageable` (Spring resolves from `?page=0&size=20&sort=name,asc`); default via
  `@PageableDefault(size = 20)`, cap via `PageableHandlerMethodArgumentResolverCustomizer#setMaxPageSize`.
- Use Java records for DTOs — canonical constructor, `ParameterNamesModule` auto-configured by Boot.

## DON'T

- `@RequestBody Entity` — client sends `{"id":"…","role":"ADMIN"}` and wins (mass assignment).
- `@RequestMapping` without explicit HTTP method — accepts ALL verbs.
- Multiple `@ControllerAdvice` beans without `@Order` — Spring applies them in undefined order;
  two advices handling overlapping exceptions → first match wins, second silently dropped.
- `@ResponseStatus` on an exception class when a handler advice already maps it — the annotation
  on the class is ignored once a `@ExceptionHandler` handles it; use one or the other.
- Unbounded `List<T>` returns from query endpoints — no size guard → full-table OOM.
- `produces`/`consumes` mismatch: controller declares `produces=application/json` but client sends
  `Accept: application/xml` → **406**; controller omits `consumes` but test POSTs without
  `Content-Type: application/json` → **415** in production.
- Inject `HttpServletRequest` to read headers — use `@RequestHeader`.
- Double-log: service catches + logs, then rethrows → advice logs again → two identical traces.

## Error contract (ProblemDetail / RFC 7807)

```java
// application.properties / yml
spring.mvc.problemdetails.enabled=true

@RestControllerAdvice
@Slf4j
public class GlobalExceptionHandler extends ResponseEntityExceptionHandler {

    // Override — NOT a parallel @ExceptionHandler — parent absorbs MethodArgumentNotValidException
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

    @ExceptionHandler(NotFoundException.class)
    public ProblemDetail handleNotFound(NotFoundException ex) {
        var pd = ProblemDetail.forStatus(HttpStatus.NOT_FOUND);
        pd.setType(URI.create("urn:problem:" + ex.code()));
        pd.setDetail(ex.getMessage());
        return pd;
    }

    @ExceptionHandler(Exception.class)
    public ProblemDetail handleUnexpected(Exception ex, HttpServletRequest req) {
        log.error("Unhandled on {} {}", req.getMethod(), req.getRequestURI(), ex);
        var pd = ProblemDetail.forStatus(HttpStatus.INTERNAL_SERVER_ERROR);
        pd.setType(URI.create("urn:problem:internal-error"));
        pd.setDetail("An unexpected error occurred");
        return pd;
    }
}
```

## @Order when multiple advice beans are unavoidable

Prefer a **single** advice bean; annotate `@Order(1)` on the most-specific and `@Order(2)` on `GlobalAdvice` only when the second bean comes from a library you don't own.

## @ResponseStatus on exception vs handler advice — when each

| Use `@ResponseStatus` on the exception class | Use `@ExceptionHandler` in advice |
|---|---|
| Exception is always the same HTTP status, no body needed | Need a body (ProblemDetail, field errors) |
| Exception not caught by any advice | Multiple exceptions map to the same handler |
| Simple; no Spring Security interaction | Exception carries data that shapes the response |

## Validation — @Valid on @RequestBody

```java
public record CreateUserRequest(
    @NotBlank @Email @Size(max = 254) String email,
    @NotBlank @Size(min = 2, max = 100) String name
) {}

@PostMapping
@ResponseStatus(HttpStatus.CREATED)
public UserResponse create(@RequestBody @Valid CreateUserRequest req) {
    return userService.create(req);
}
```

Use `@Validated` at class level for path/query constraints — failure raises `ConstraintViolationException` (not `MethodArgumentNotValidException`).

## Pagination contract

```java
@GetMapping
public Page<UserResponse> list(@PageableDefault(size = 20) Pageable pageable) {
    return userService.list(pageable);  // ?page=0&size=50&sort=createdAt,desc
}

// @PageableDefault has NO max attribute — the size CAP is a resolver setting:
@Bean
PageableHandlerMethodArgumentResolverCustomizer pageableCustomizer() {
    return r -> r.setMaxPageSize(100);   // ?size=10000 silently clamps to 100
}
```

Never return unbounded `List<T>` — a table with 10M rows will OOM. Cap via the resolver customizer.

## Content negotiation pitfalls

| Symptom | Root cause | Fix |
|---|---|---|
| **406 Not Acceptable** | Client `Accept` header doesn't match `produces` | Add correct `produces` or ensure client sends `Accept: application/json` |
| **415 Unsupported Media Type** | POST without `Content-Type: application/json` | Add `consumes = APPLICATION_JSON_VALUE` to document the contract; fix client |
| Advice override never called | Missing `spring.mvc.problemdetails.enabled=true` for standard MVC errors | Set property; or override `handleNoHandlerFoundException` etc. explicitly |

## When NOT to use @RestControllerAdvice

- **Inside a transaction**: advice fires after the method returns — TX already rolled back; use try/catch in the service.
- **Spring Security exceptions**: `AuthenticationException`/`AccessDeniedException` go to `AuthenticationEntryPoint`/`AccessDeniedHandler`; advice never sees them by default.

See `claudehut:implement` skill for full Jackson config and integration test patterns.
