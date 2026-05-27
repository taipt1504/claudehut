# Router + Handler Pattern

## Why split

- **Routing** (URL → handler method) is declarative.
- **Handler** (request → response) is pure Mono transformation, testable in isolation.
- Easier than `@RestController` to test without `@WebFluxTest` overhead.

## Handler structure

```java
@Component
@RequiredArgsConstructor
public class UserHandler {

    private final UserService service;
    private final Validator validator;

    public Mono<ServerResponse> create(ServerRequest req) {
        return req.bodyToMono(CreateUserRequest.class)
            .doOnNext(this::validate)
            .flatMap(service::create)
            .flatMap(user -> ServerResponse
                .status(HttpStatus.CREATED)
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue(toResponse(user)));
    }

    public Mono<ServerResponse> list(ServerRequest req) {
        int page = req.queryParam("page").map(Integer::parseInt).orElse(0);
        int size = req.queryParam("size").map(Integer::parseInt).orElse(20);
        return service.list(page, size)
            .collectList()
            .flatMap(users -> ServerResponse.ok().bodyValue(users));
    }

    public Mono<ServerResponse> get(ServerRequest req) {
        String id = req.pathVariable("id");
        return service.findById(id)
            .map(this::toResponse)
            .flatMap(resp -> ServerResponse.ok().bodyValue(resp))
            .switchIfEmpty(ServerResponse.notFound().build());
    }

    private void validate(CreateUserRequest req) {
        Set<ConstraintViolation<CreateUserRequest>> violations = validator.validate(req);
        if (!violations.isEmpty()) {
            throw new ConstraintViolationException(violations);
        }
    }

    private UserResponse toResponse(User u) {
        return new UserResponse(u.id(), u.email(), u.name());
    }
}
```

## Router configuration

```java
@Configuration
@RequiredArgsConstructor
public class UserRouterConfig {

    @Bean
    public RouterFunction<ServerResponse> userRoutes(UserHandler h) {
        return RouterFunctions.route()
            .path("/api/v1/users", builder -> builder
                .GET("/{id}", h::get)
                .GET("", h::list)
                .POST("", accept(MediaType.APPLICATION_JSON), h::create)
                .PUT("/{id}", accept(MediaType.APPLICATION_JSON), h::update)
                .DELETE("/{id}", h::delete)
                .filter(authFilter())
                .filter(loggingFilter())
            )
            .build();
    }

    private HandlerFilterFunction<ServerResponse, ServerResponse> authFilter() {
        return (req, next) -> req.principal()
            .switchIfEmpty(ServerResponse.status(HttpStatus.UNAUTHORIZED).build().flatMap(Mono::error))
            .flatMap(p -> next.handle(req));
    }

    private HandlerFilterFunction<ServerResponse, ServerResponse> loggingFilter() {
        return (req, next) -> {
            long start = System.currentTimeMillis();
            return next.handle(req)
                .doOnTerminate(() -> log.info("{} {} {}ms",
                    req.method(), req.path(), System.currentTimeMillis() - start));
        };
    }
}
```

## Testing the Handler

```java
class UserHandlerTest {

    UserService service = mock(UserService.class);
    Validator validator = Validation.buildDefaultValidatorFactory().getValidator();
    UserHandler handler = new UserHandler(service, validator);

    @Test
    void shouldReturn404_whenUserNotFound() {
        when(service.findById("x")).thenReturn(Mono.empty());

        ServerRequest req = MockServerRequest.builder().pathVariable("id", "x").build();
        StepVerifier.create(handler.get(req))
            .assertNext(resp -> assertThat(resp.statusCode()).isEqualTo(HttpStatus.NOT_FOUND))
            .verifyComplete();
    }
}
```

## Anti-pattern: subscribe inside handler

```java
// BAD
public Mono<ServerResponse> create(ServerRequest req) {
    service.create(...).subscribe();  // ← double subscription, Spring already subscribes
    return ServerResponse.ok().build();
}
```

```java
// GOOD
public Mono<ServerResponse> create(ServerRequest req) {
    return service.create(...).flatMap(u -> ServerResponse.ok().bodyValue(u));
}
```
