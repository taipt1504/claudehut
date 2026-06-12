---
id: rules/framework/webflux
paths:
  - "**/*Handler.java"
  - "**/*Router.java"
  - "**/*ReactiveService.java"
stack: "web=webflux"
severity: high
tags: [webflux, reactive, reactor, handler, router]
---
<!-- ClaudeHut rule template — generated into .claude/rules/framework/webflux.md by claudehut-init. Reused & enhanced from committed rules/framework/webflux.md. -->

# Spring WebFlux Handler Rules

## DO

- Use `RouterFunction` + `Handler` pattern (preferred over `@RestController`).
- Return `Mono<ServerResponse>` from every handler method.
- Use `WebTestClient` for tests; `StepVerifier` for unit-level chain tests.
- Propagate security/trace via Reactor Context — never `ThreadLocal`/MDC directly.
- Offload unavoidable blocking calls: `Mono.fromCallable(() -> legacy.call()).subscribeOn(Schedulers.boundedElastic())`.

## DON'T

- `.block()` / `.blockFirst()` / `.blockLast()` anywhere in a production reactive chain — starves the Netty event loop; manifests as timeouts under load.
- `Thread.sleep()` in an operator — use `Mono.delay` / `delayElements`.
- Synchronous I/O (JDBC, `RestTemplate`, `FileReader`) without `subscribeOn(boundedElastic)`.
- `.subscribe()` inside a handler — Spring subscribes for you; manual subscribe causes fire-and-forget, context loss, and swallowed errors.
- `subscribeOn(Schedulers.parallel())` for blocking work — that pool is for CPU; blocking it starves all async computation.
- Unbounded `flatMap` — always pass a concurrency cap (see table below).

## flatMap vs concatMap vs flatMapSequential

| Operator | Order preserved? | Concurrency | Use when |
|---|---|---|---|
| `flatMap(fn, N)` | No | N (default 256 — always cap it) | Max throughput, ordering irrelevant (e.g. parallel DB lookups) |
| `concatMap(fn)` | Yes | 1 (sequential) | Strict ordering required or downstream is not thread-safe |
| `flatMapSequential(fn, N)` | Yes (merges in order) | N concurrent | Ordered output + parallelism (e.g. paginated enrichment) |
| `switchMap(fn)` | Latest only | 1 (cancels prior) | Latest-wins (typeahead, live reload — drops stale in-flight requests) |

Cap `flatMap` to match your connection pool: `flatMap(fn, poolMaxSize)`.

## Error recovery

| Operator | Returns | Use when |
|---|---|---|
| `onErrorResume(ex, fn)` | Publisher | Fall back to cache, alternate source, or empty with logging |
| `onErrorReturn(ex, value)` | scalar T | Simple scalar default (e.g. `0`, `false`, sentinel object) |
| `onErrorMap(ex, fn)` | re-throws mapped | Translate infrastructure exception → domain exception (always wrap cause) |
| `retryWhen(Retry.backoff(n, dur))` | retries | Transient failures (network, throttle); set `maxAttempts` + `maxBackoff` |

```java
// Retry with exponential backoff — transient HTTP 503
service.call()
    .retryWhen(Retry.backoff(3, Duration.ofMillis(200))
                   .maxBackoff(Duration.ofSeconds(2))
                   .filter(ex -> ex instanceof ServiceUnavailableException));
```

Never swallow errors silently: `onErrorResume(e -> Mono.empty())` hides bugs.

## Reactor Context (replaces ThreadLocal / MDC)

Context flows **up** the assembly chain — write at the bottom, reads above will see it.

```java
// Write (e.g. in a filter or gateway)
return chain.filter(exchange)
    .contextWrite(ctx -> ctx.put("traceId", traceId));

// Read inside a service operator
public Mono<User> findById(UUID id) {
    return Mono.deferContextual(ctx -> {
        String traceId = ctx.getOrDefault("traceId", "none");
        log.debug("trace={}", traceId);
        return userRepo.findById(id);
    });
}
```

`ThreadLocal`/MDC is lost when Reactor switches threads between operators — use
`contextWrite` + `deferContextual` instead.  For operator-level access use
`transformDeferredContextual`; for value-level use `Mono.deferContextual`.

## Mono.defer — lazy / per-subscriber evaluation

`Mono.just(val)` captures `val` **at assembly time** (eager).  
`Mono.defer(() -> Mono.just(val))` evaluates the supplier **per subscription** (lazy).

```java
// BAD — timestamp captured once at startup
Mono<Instant> now = Mono.just(Instant.now());

// GOOD — fresh timestamp per subscriber
Mono<Instant> now = Mono.defer(() -> Mono.just(Instant.now()));
```

Use `defer` whenever the source must be re-evaluated per subscriber: mutable state,
`Mono.error(new Ex())` factories, or conditional logic.

## Blocking offload pattern

```java
// Wrapping a legacy blocking call
public Mono<Report> generateReport(UUID id) {
    return Mono.fromCallable(() -> legacyReportService.generate(id))  // blocking
               .subscribeOn(Schedulers.boundedElastic());              // offload
}
```

`boundedElastic` caps thread creation (default `10 × CPU` threads + 100k task queue).
Never use `parallel()` for blocking work — it has only `CPU` threads and no queue.

Install **BlockHound** to catch accidental blocking in tests:

```java
@BeforeAll
static void installBlockHound() {
    BlockHound.install();  // reactor.tools:reactor-tools:test
}
```

BlockHound throws `BlockingOperationError` when `.block()` or a blocking JDK call
lands on a reactive thread — catches issues CI misses.

## Correct example

```java
@Component
@RequiredArgsConstructor
public class UserHandler {
    private final UserService service;

    public Mono<ServerResponse> getById(ServerRequest req) {
        UUID id = UUID.fromString(req.pathVariable("id"));
        return service.findById(id)
            .flatMap(user -> ServerResponse.ok().bodyValue(user))
            .switchIfEmpty(ServerResponse.notFound().build())
            .onErrorMap(IllegalArgumentException.class,
                        e -> new ResponseStatusException(BAD_REQUEST, e.getMessage(), e));
    }
}
```

## Anti-patterns

```java
// Blocks the Netty event-loop — server hangs under load
User user = service.findById(id).block();  // BAD

// subscribe() inside handler — fire-and-forget, errors swallowed, context lost
req.bodyToMono(Cmd.class).flatMap(service::create).subscribe();  // BAD

// switchMap drops in-flight — use flatMap when all results are needed
Flux.fromIterable(ids).switchMap(repo::findById);  // BAD — silently drops results

// Unbounded flatMap — exhausts DB connection pool
Flux.fromIterable(thousandsOfIds).flatMap(repo::findById);  // BAD — add concurrency cap
```

## References

- Detailed patterns: `claudehut:implement` skill → reactive playbook.
- Reactor reference: https://projectreactor.io/docs/core/release/reference/
