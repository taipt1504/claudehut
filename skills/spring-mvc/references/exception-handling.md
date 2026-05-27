# Exception Handling — Spring MVC + ProblemDetail

## Centralize in @RestControllerAdvice

```java
@RestControllerAdvice
@Slf4j
public class GlobalExceptionHandler {

    @ExceptionHandler(DuplicateUserException.class)
    public ProblemDetail handleDuplicate(DuplicateUserException ex) {
        var problem = ProblemDetail.forStatus(HttpStatus.CONFLICT);
        problem.setType(URI.create("urn:problem:duplicate-user"));
        problem.setTitle("Duplicate user");
        problem.setDetail(ex.getMessage());
        return problem;
    }

    @ExceptionHandler(MethodArgumentNotValidException.class)
    public ProblemDetail handleValidation(MethodArgumentNotValidException ex) {
        var problem = ProblemDetail.forStatus(HttpStatus.BAD_REQUEST);
        problem.setType(URI.create("urn:problem:invalid-input"));
        problem.setTitle("Validation failed");
        problem.setProperty("errors", ex.getBindingResult().getFieldErrors().stream()
            .map(e -> Map.of("field", e.getField(), "message", e.getDefaultMessage()))
            .toList());
        return problem;
    }

    @ExceptionHandler(AccessDeniedException.class)
    @ResponseStatus(HttpStatus.FORBIDDEN)
    public ProblemDetail handleForbidden(AccessDeniedException ex) {
        return ProblemDetail.forStatusAndDetail(HttpStatus.FORBIDDEN, "access denied");
    }

    @ExceptionHandler(Exception.class)
    public ProblemDetail handleUnknown(Exception ex) {
        log.error("Unhandled exception", ex);
        return ProblemDetail.forStatusAndDetail(HttpStatus.INTERNAL_SERVER_ERROR, "internal error");
    }
}
```

## RFC 7807 — ProblemDetail format

```json
{
  "type": "urn:problem:duplicate-user",
  "title": "Duplicate user",
  "status": 409,
  "detail": "a@b.com already exists",
  "instance": "/users",
  "timestamp": "2025-05-27T10:42:00Z"
}
```

Custom `type` URIs:

- `urn:problem:duplicate-<resource>`
- `urn:problem:invalid-input`
- `urn:problem:not-found`
- `urn:problem:rate-limit-exceeded`
- `urn:problem:upstream-failure`

## Don't leak stack traces

In production, never serialize raw exception messages or stack traces. Use:

- `ProblemDetail.setDetail("invalid email format")` — controlled message.
- Log full exception server-side: `log.error("...", ex)`.

## Hierarchy

```
RuntimeException
  ├── DomainException (your project's base)
  │   ├── ValidationException
  │   ├── NotFoundException
  │   ├── DuplicateException
  │   └── BusinessRuleException
  └── InfrastructureException
      ├── DatabaseException
      └── ExternalServiceException
```

Each domain exception → one `@ExceptionHandler` returning specific ProblemDetail.

## Tests

```java
@WebMvcTest(UserController.class)
@Import(GlobalExceptionHandler.class)
class UserControllerTest {

    @MockBean UserService userService;
    @Autowired MockMvc mockMvc;

    @Test
    void shouldReturn409_whenDuplicate() throws Exception {
        when(userService.create(any())).thenThrow(new DuplicateUserException("a@b.com"));

        mockMvc.perform(post("/users")
                .contentType(MediaType.APPLICATION_JSON)
                .content("""
                    {"email":"a@b.com","name":"Alice"}
                """))
            .andExpect(status().isConflict())
            .andExpect(jsonPath("$.type").value("urn:problem:duplicate-user"))
            .andExpect(jsonPath("$.detail").value("a@b.com"));
    }
}
```
