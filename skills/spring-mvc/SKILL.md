---
name: spring-mvc
description: Spring MVC REST controller conventions for Java Spring Boot 3.x. Auto-loads when editing `**/*Controller.java` files in projects with web_stack=mvc. Covers @RestController, validation, ResponseEntity, @ControllerAdvice exception handling, RFC 7807 ProblemDetail, JWT auth integration.
---

# Spring MVC

Conventions for Servlet-stack REST controllers.

## Quick start

```java
@RestController
@RequestMapping(value = "/users", produces = MediaType.APPLICATION_JSON_VALUE)
@RequiredArgsConstructor
public class UserController {

    private final UserService userService;

    @PostMapping
    @PreAuthorize("hasRole('ADMIN')")
    public ResponseEntity<UserResponse> create(@RequestBody @Valid CreateUserRequest req) {
        UserResponse created = userService.create(req);
        return ResponseEntity.status(HttpStatus.CREATED).body(created);
    }

    @GetMapping("/{id}")
    public UserResponse get(@PathVariable String id) {
        return userService.get(id);
    }
}
```

Detailed patterns: `references/controller-patterns.md`. Exception handling + ProblemDetail: `references/exception-handling.md`. Validation: `references/validation.md`. Anti-patterns: `references/anti-patterns.md`.

## Assets

- `assets/templates/RestController.java.tmpl` — controller skeleton.
- `assets/templates/ControllerAdvice.java.tmpl` — exception handler skeleton.
- `assets/templates/RequestDto.java.tmpl` — `*Request` DTO record.

## Hard rules

- ALWAYS `@RestController` for JSON APIs (not `@Controller`).
- ALWAYS explicit `produces` and `consumes` where ambiguous.
- ALWAYS `@Valid` on `@RequestBody` and `@RequestParam` where validation needed.
- NEVER `@RequestBody Entity` — use dedicated `*Request` DTO (mass-assignment).
- NEVER inject `HttpServletRequest` for header reading — use `@RequestHeader`.
- NEVER throw raw `RuntimeException` to client — use `@ControllerAdvice` + ProblemDetail.

## Exit criteria

- [ ] Controller annotated `@RestController` + explicit `@RequestMapping`
- [ ] All request bodies have validated DTOs
- [ ] Exception paths handled via `@ControllerAdvice`
- [ ] Method-level auth declared (`@PreAuthorize` or SecurityFilterChain)
