---
id: rules/framework/spring-mvc
paths:
  - "**/*Controller.java"
stack: "web=mvc"
severity: high
tags: [spring-mvc, rest, controller]
---


# Spring MVC Controller Rules

## DO

- `@RestController` for JSON APIs (not `@Controller`).
- Explicit `@RequestMapping(produces=, consumes=)`.
- `@Valid` on `@RequestBody`.
- Return `ResponseEntity<T>` when status varies; direct DTO when always 200.
- Centralize exception handling in `@RestControllerAdvice` with `ProblemDetail`.

## DON'T

- `@RequestBody Entity` (mass assignment).
- Throw raw `RuntimeException` to client.
- Inject `HttpServletRequest` for header reads — use `@RequestHeader`.
- `@RequestMapping` without explicit HTTP method — allows ALL methods.

## Correct example

```java
@RestController
@RequestMapping(value = "/users", produces = MediaType.APPLICATION_JSON_VALUE)
@RequiredArgsConstructor
public class UserController {

    private final UserService userService;

    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    public UserResponse create(@RequestBody @Valid CreateUserRequest req) {
        return userService.create(req);
    }

    @GetMapping("/{id}")
    public UserResponse get(@PathVariable String id) {
        return userService.get(id);
    }
}
```

## Incorrect example

```java
@Controller
public class UserController {

    @PostMapping("/users")
    public User create(HttpServletRequest req) {  // raw request, no validation, mass assignment
        ...
    }
}
```

## References

- See `claudehut:spring-mvc` skill for detailed patterns.
- See `claudehut:jackson` skill for request/response DTO conventions.
- ADR template: `docs/adr/NNNN-rest-api-style.md`.
