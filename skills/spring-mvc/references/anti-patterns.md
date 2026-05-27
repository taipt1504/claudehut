# Spring MVC Anti-Patterns

| Anti-pattern | Issue | Fix |
|--------------|-------|-----|
| `@Controller` for JSON API | Returns view name, not data | Use `@RestController` |
| `@RequestBody UserEntity` | Mass assignment: client can set ANY field | Use `*Request` DTO with explicit fields |
| `@PathVariable("id")` without `String` type annotation match | Type conversion silent fail | Always specify type; use `@PathVariable String id` |
| Missing `@Valid` on `@RequestBody` | Validation skipped | Always add `@Valid` |
| Returning `Entity` directly | Lazy loading exception on serialization; leaks impl | Map to `Response` DTO |
| Manual `HttpServletRequest` for headers | Bypasses Spring binding | Use `@RequestHeader` |
| `throw new RuntimeException("...")` | Generic 500 to client | Custom domain exception + ControllerAdvice |
| `@RequestMapping` without explicit method | Allows ALL HTTP methods | Always use `@GetMapping`, `@PostMapping`, etc. |
| Catching `Exception` in controller | Defeats ControllerAdvice | Let it bubble; ControllerAdvice handles |
| Logging in catch + rethrow | Duplicate log entries | Log OR rethrow, not both (ControllerAdvice will log) |
| `produces = "application/json"` instead of `MediaType.APPLICATION_JSON_VALUE` | String literal typo risk | Use `MediaType.*` constants |
| Single-call `@CrossOrigin("*")` annotation | Inconsistent CORS across endpoints | Configure globally in `WebMvcConfigurer` |
| `@Async` on controller method | Returns immediately without response | Return `CompletableFuture<T>` or use proper async style |
| Mixing `ResponseEntity` and direct return | Inconsistent error handling | Pick one style per controller |
| Path param matching DTO field literally | Confusing | Name path params with explicit purpose: `{userId}` not `{id}` |
| Versioning via header on some endpoints, URL on others | Inconsistent | Choose one strategy: `/api/v1/...` URL versioning is simplest |

## Heavy anti-patterns (Critical / High in review)

### Mass assignment

```java
// BAD
@PostMapping
public User create(@RequestBody User user) { return repo.save(user); }
// Client can send {"id": "evil", "role": "ADMIN", ...} and override
```

```java
// GOOD
@PostMapping
public UserResponse create(@RequestBody @Valid CreateUserRequest req) {
    var user = userMapper.toEntity(req);  // mapper ignores fields not in request
    return userMapper.toResponse(repo.save(user));
}
```

### Open redirect

```java
// BAD
@GetMapping("/redirect")
public RedirectView redirect(@RequestParam String url) {
    return new RedirectView(url);  // user controls destination
}
```

```java
// GOOD
@GetMapping("/redirect")
public RedirectView redirect(@RequestParam String target) {
    var allowed = Set.of("home", "profile", "settings");
    if (!allowed.contains(target)) throw new IllegalArgumentException("unknown target");
    return new RedirectView("/" + target);
}
```
