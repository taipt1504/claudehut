# StepVerifier — Reactive Testing

## Basic flow

```java
@Test
void shouldEmitUser_whenFound() {
    when(userRepo.findById("u1")).thenReturn(Mono.just(new User("u1", "Alice")));

    StepVerifier.create(service.findById("u1"))
        .assertNext(u -> assertThat(u.name()).isEqualTo("Alice"))
        .verifyComplete();
}
```

## Empty source

```java
@Test
void shouldEmitEmpty_whenNotFound() {
    when(userRepo.findById("missing")).thenReturn(Mono.empty());

    StepVerifier.create(service.findById("missing"))
        .verifyComplete();  // no element, no error
}
```

## Error path

```java
@Test
void shouldErrorWith_DuplicateException_whenDuplicate() {
    when(userRepo.existsByEmail("a@b.com")).thenReturn(Mono.just(true));

    StepVerifier.create(service.create(new CreateUserRequest("a@b.com", "Alice")))
        .expectError(DuplicateUserException.class)
        .verify();
}
```

## Multiple emissions (Flux)

```java
@Test
void shouldEmitAllUsers() {
    when(userRepo.findAll()).thenReturn(Flux.just(
        new User("u1", "Alice"),
        new User("u2", "Bob")
    ));

    StepVerifier.create(service.listAll())
        .expectNextMatches(u -> u.name().equals("Alice"))
        .expectNextMatches(u -> u.name().equals("Bob"))
        .verifyComplete();
}
```

## Virtual time

```java
@Test
void shouldRetry_with2sBackoff() {
    StepVerifier.withVirtualTime(() ->
            client.fetchWithRetry()
                .retryWhen(Retry.backoff(3, Duration.ofSeconds(2))))
        .expectSubscription()
        .expectNoEvent(Duration.ofSeconds(2))
        .expectNext("result")
        .verifyComplete();
}
```

`withVirtualTime` skips real waits — tests are fast.

## Backpressure verification

```java
@Test
void shouldRespectBackpressure() {
    StepVerifier.create(service.streamMany(), 2)  // request only 2
        .expectNextCount(2)
        .thenCancel()
        .verify();
}
```

## Pattern matching

```java
StepVerifier.create(service.create(req))
    .expectNextMatches(user ->
        user.id() != null && user.email().equals("a@b.com"))
    .verifyComplete();
```

## Context

```java
StepVerifier.create(service.findById("x").contextWrite(Context.of("requestId", "abc")))
    .assertNext(u -> ...)
    .verifyComplete();
```

## Common mistakes

- Forgetting `.verifyComplete()` or `.verify()` at the end → test passes silently.
- Using `.assertNext` for Flux with multiple elements → only checks first.
- Not setting `withVirtualTime` for time-based operators → test takes real wall-clock time.

## WebTestClient for handler integration

```java
@WebFluxTest(controllers = UserHandler.class)
class UserHandlerWebTest {

    @Autowired WebTestClient client;
    @MockBean UserService service;

    @Test
    void shouldReturn200_whenUserExists() {
        when(service.findById("u1")).thenReturn(Mono.just(new User("u1", "Alice")));

        client.get().uri("/users/u1")
            .exchange()
            .expectStatus().isOk()
            .expectBody()
            .jsonPath("$.name").isEqualTo("Alice");
    }
}
```
