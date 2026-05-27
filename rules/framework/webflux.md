---
id: rules/framework/webflux
paths:
  - "**/*Handler.java"
stack: "web=webflux"
severity: high
tags: [webflux, reactive, handler, router]
---


# Spring WebFlux Handler Rules

## DO

- Use RouterFunction + Handler pattern (preferred over `@RestController`).
- Return `Mono<ServerResponse>` from handler methods.
- Use `WebTestClient` for tests.
- Propagate context via Reactor Context.
- `subscribeOn(Schedulers.boundedElastic())` for blocking I/O wrapped in `Mono.fromCallable`.

## DON'T

- `.block()`, `.blockLast()`, `.blockFirst()` in production code path.
- `Thread.sleep` in operator chain.
- Synchronous I/O (JDBC, RestTemplate, FileReader without scheduler).
- `.subscribe(...)` in handler — Spring subscribes for you.
- `subscribeOn(Schedulers.parallel())` for blocking work (use boundedElastic).

## Correct example

```java
@Component
@RequiredArgsConstructor
public class UserHandler {
    private final UserService service;

    public Mono<ServerResponse> get(ServerRequest req) {
        String id = req.pathVariable("id");
        return service.findById(id)
            .flatMap(user -> ServerResponse.ok().bodyValue(user))
            .switchIfEmpty(ServerResponse.notFound().build());
    }
}
```

## Incorrect example

```java
public Mono<ServerResponse> get(ServerRequest req) {
    User user = service.findById(req.pathVariable("id")).block();  // BLOCKS event loop
    return ServerResponse.ok().bodyValue(user);
}
```

## References

- See `claudehut:spring-webflux` skill for detailed patterns.
- See `claudehut:r2dbc` skill for reactive DB access.
- Reactor Context propagation: `claudehut:spring-webflux/references/context-propagation.md`.
