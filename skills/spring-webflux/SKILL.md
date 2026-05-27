---
name: spring-webflux
description: Spring WebFlux conventions for Java Spring Boot 3.x reactive stack. Auto-loads when editing `**/*Handler.java` or `**/*Controller.java` in projects with web_stack=webflux. Covers RouterFunctions + Handler pattern, schedulers, context propagation, StepVerifier testing, backpressure.
---

# Spring WebFlux

Reactive endpoints via RouterFunctions + Handlers. Prefer over `@RestController` in WebFlux for testability.

## Quick start (Handler + RouterFunction)

```java
@Component
@RequiredArgsConstructor
public class UserHandler {
    private final UserService service;

    public Mono<ServerResponse> create(ServerRequest req) {
        return req.bodyToMono(CreateUserRequest.class)
            .flatMap(service::create)
            .flatMap(user -> ServerResponse.status(HttpStatus.CREATED).bodyValue(user));
    }

    public Mono<ServerResponse> get(ServerRequest req) {
        String id = req.pathVariable("id");
        return service.findById(id)
            .flatMap(user -> ServerResponse.ok().bodyValue(user))
            .switchIfEmpty(ServerResponse.notFound().build());
    }
}

@Configuration
public class UserRouterConfig {
    @Bean
    public RouterFunction<ServerResponse> userRoutes(UserHandler h) {
        return RouterFunctions.route()
            .path("/users", b -> b
                .GET("/{id}", h::get)
                .POST("", accept(MediaType.APPLICATION_JSON), h::create))
            .build();
    }
}
```

Detailed: `references/router-handler-pattern.md`, `references/schedulers.md`, `references/context-propagation.md`, `references/stepverifier-testing.md`, `references/anti-patterns.md`.

## Assets

- `assets/templates/Handler.java.tmpl`
- `assets/templates/RouterConfig.java.tmpl`

## Hard rules

- NEVER `.block()` in reactive chain. NEVER `Thread.sleep`. NEVER blocking I/O (JDBC, RestTemplate).
- ALWAYS `boundedElastic` scheduler for unavoidable blocking I/O wrapped in `Mono.fromCallable`.
- ALWAYS propagate context via Reactor Context for tracing/MDC.
- PREFER Handler + RouterFunction over `@RestController` (better testability, explicit routing).
- USE `WebTestClient` for tests, not `MockMvc`.

## Exit criteria

- [ ] No `.block()` in production code path
- [ ] All blocking I/O wrapped + `subscribeOn(boundedElastic)`
- [ ] Tests use `StepVerifier` or `WebTestClient`
- [ ] Context propagation verified for tracing
