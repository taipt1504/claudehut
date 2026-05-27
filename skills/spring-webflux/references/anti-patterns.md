# WebFlux Anti-Patterns

| Anti-pattern | Why bad | Fix |
|--------------|---------|-----|
| `.block()` in handler/service | Blocks event-loop thread; throughput collapses | Return `Mono<T>`; let framework subscribe |
| `.subscribe()` in handler | Double subscription, fire-and-forget | Return the `Mono<ServerResponse>` |
| Blocking JDBC in chain | Same as `.block()` | Use R2DBC or wrap in `Mono.fromCallable + subscribeOn(boundedElastic)` |
| `RestTemplate` in reactive chain | Blocking | Use `WebClient` |
| `Thread.sleep` in operator | Blocking | Use `Mono.delay(Duration.ofSeconds(N))` |
| `MDC.put(...)` directly | ThreadLocal escapes to wrong thread | Use Reactor Context + `Hooks.enableAutomaticContextPropagation()` |
| `subscribeOn(parallel())` for blocking | Saturates CPU pool | Use `boundedElastic` |
| Unbounded `Flux.fromIterable(largeList)` | Memory blowup, no backpressure | `.limitRate(100)` or stream from source |
| `.cache()` on infinite Flux | Memory leak | Bound it or don't cache |
| `Sinks.many().multicast()` without `onBackpressureBuffer(size)` | Subscriber lag → OOM | Explicit buffer size |
| `flatMap` without concurrency limit on hot path | Resource exhaustion | `flatMap(fn, 8)` (concurrency) |
| Mixing `Mono<T>` and `T` returns | Confusing reactive contract | Pick one style per service |
| `@Async` on reactive method | Defeats reactive scheduler | Use Reactor operators |
| Hot Flux from `Sinks.many().replay()` cached forever | Unbounded retention | `replay().latest()` or limit by count |
| `repeat()` / `expand()` without limit | Infinite loop | `repeat(N)` or `repeatWhen` with stopping condition |
| Returning a `Mono` from a `void` method (fire-and-forget) | Errors silently swallowed | Subscribe explicitly or return `Mono<Void>` |
| Throwing exception synchronously in reactive method | Bypasses chain error handling | `Mono.error(new Exception())` |
| Setting `Hooks.onOperatorDebug()` in production | 5–10× perf cost | Only in dev/test |

## Worst offenders (review will flag Critical)

### `.block()` in chain

```java
// BAD
public Mono<UserResponse> get(String id) {
    User user = userRepo.findById(id).block();  // ← Critical
    return Mono.just(toResponse(user));
}
```

```java
// GOOD
public Mono<UserResponse> get(String id) {
    return userRepo.findById(id).map(this::toResponse);
}
```

### Blocking JDBC

```java
// BAD
public Mono<User> findById(String id) {
    return Mono.fromCallable(() -> jdbcTemplate.queryForObject(...));  // ← blocks event loop
}
```

```java
// GOOD — switch to R2DBC repository
public Mono<User> findById(String id) {
    return r2dbcRepo.findById(id);
}
```

```java
// ACCEPTABLE — if legacy JDBC unavoidable
public Mono<User> findById(String id) {
    return Mono.fromCallable(() -> jdbcTemplate.queryForObject(...))
        .subscribeOn(Schedulers.boundedElastic());
}
```
