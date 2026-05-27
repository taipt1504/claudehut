# Context Propagation

## Reactor Context — replacement for ThreadLocal

```java
public Mono<User> findById(String id) {
    return Mono.deferContextual(ctx -> {
        String requestId = ctx.get("requestId");
        log.info("Looking up user {} for request {}", id, requestId);
        return userRepo.findById(id);
    });
}
```

Caller puts context:

```java
chain
    .contextWrite(Context.of("requestId", UUID.randomUUID().toString()))
    .subscribe();
```

## MDC propagation

Use Micrometer's `ReactorContextTools` or set up `Hooks.enableAutomaticContextPropagation()` (Boot 3.2+):

```java
@Configuration
public class ContextPropagationConfig {
    @PostConstruct
    public void init() {
        Hooks.enableAutomaticContextPropagation();
    }
}
```

Then MDC values from upstream filters automatically propagate through Mono/Flux chains.

## Manual MDC bridge

```java
public Mono<Void> logInChain(String message) {
    return Mono.deferContextual(ctx -> {
        try (var ignored = MDC.putCloseable("requestId", ctx.get("requestId"))) {
            log.info(message);
            return Mono.empty();
        }
    });
}
```

## Tracing (Micrometer Observation)

```java
public Mono<User> findById(String id) {
    return Mono.deferContextual(ctx -> {
        var observation = Observation.start("user.findById", observationRegistry)
            .lowCardinalityKeyValue("id", id);
        return userRepo.findById(id)
            .doOnSuccess(u -> observation.stop())
            .doOnError(observation::error);
    });
}
```

Better: use `@Observed` annotation (auto-instruments).

## SecurityContext in reactive chain

```java
public Mono<User> currentUserDetails() {
    return ReactiveSecurityContextHolder.getContext()
        .map(SecurityContext::getAuthentication)
        .map(Principal::getName)
        .flatMap(userRepo::findByUsername);
}
```

## Anti-patterns

- Using `MDC.put(...)` directly in reactive chain → ThreadLocal escapes to wrong thread.
- Static state in handler classes → race conditions across requests.
- Subscribing in a different scope than context was set → lost context.
