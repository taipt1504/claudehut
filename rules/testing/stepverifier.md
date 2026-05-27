---
id: rules/testing/stepverifier
applies-to: "**/*Test.java"
severity: medium
tags: [stepverifier, reactor, webflux, reactive]
---

# StepVerifier Conventions

## DO

- Use `StepVerifier.create(mono)` for reactive testing.
- `.assertNext(...)` for single element verification.
- `.expectError(SomeException.class)` for error path.
- `.verifyComplete()` to assert successful completion.
- Use `withVirtualTime` for time-based operators.
- Test in scope of one Mono/Flux per test method.

## DON'T

- `.subscribe(...).block()` in test — defeats reactive testing.
- Forget `.verifyComplete()` / `.verify()` — test passes silently.
- Use `.thenAwait(Duration.ofSeconds(...))` outside virtual time — wastes wall-clock.
- Test multiple Monos in one test — split.

## Patterns

### Success path

```java
@Test
void shouldEmitUser_whenFound() {
    StepVerifier.create(service.findById("u1"))
        .assertNext(u -> {
            assertThat(u.id()).isEqualTo("u1");
            assertThat(u.email()).isEqualTo("a@b.com");
        })
        .verifyComplete();
}
```

### Empty

```java
@Test
void shouldEmitEmpty_whenNotFound() {
    StepVerifier.create(service.findById("missing"))
        .verifyComplete();  // no element, no error
}
```

### Error

```java
@Test
void shouldEmitDuplicateError() {
    StepVerifier.create(service.create(req))
        .expectError(DuplicateUserException.class)
        .verify();
}
```

### Flux with multiple emissions

```java
@Test
void shouldEmitAllUsers() {
    StepVerifier.create(service.listAll())
        .expectNextCount(3)
        .verifyComplete();

    // Or with specific assertions
    StepVerifier.create(service.listAll())
        .assertNext(u -> assertThat(u.name()).isEqualTo("Alice"))
        .assertNext(u -> assertThat(u.name()).isEqualTo("Bob"))
        .assertNext(u -> assertThat(u.name()).isEqualTo("Carol"))
        .verifyComplete();
}
```

### Virtual time for backoff/retry

```java
@Test
void shouldRetry_with2sBackoff() {
    StepVerifier.withVirtualTime(() ->
            client.fetch().retryWhen(Retry.backoff(3, Duration.ofSeconds(2))))
        .expectSubscription()
        .expectNoEvent(Duration.ofSeconds(2))
        .expectNext("result")
        .verifyComplete();
}
```

### Context

```java
@Test
void shouldUseContextValue() {
    StepVerifier.create(service.process().contextWrite(Context.of("requestId", "abc")))
        .expectNextMatches(r -> r.equals("processed-abc"))
        .verifyComplete();
}
```

### Backpressure

```java
@Test
void shouldRespectBackpressure() {
    StepVerifier.create(service.streamMany(), 2)  // request only 2
        .expectNextCount(2)
        .thenCancel()
        .verify();
}
```

## Common mistakes

| Mistake | Fix |
|---------|-----|
| Forgetting `.verifyComplete()` | Test passes silently |
| Using `.thenAwait(Duration)` outside virtual time | Slow tests |
| `.expectNext(value)` for object with non-trivial equals | Use `.expectNextMatches(predicate)` |
| Subscribing manually instead of StepVerifier | No automatic verification |
| Testing multiple Monos sequentially in one test | Split into multiple tests |
