# Spring WebFlux + R2DBC + Project Reactor — Best-Practice Playbook

<!-- Researched via Project Reactor Reference Guide (/websites/projectreactor_io_core_release_reference),
     Spring Framework 6.2 Reference (/websites/spring_io_spring-framework_reference_6_2),
     Spring Data Relational (/spring-projects/spring-data-relational).
     Target: Spring Boot 3.2+ / Reactor 3.6 / Java 17+ -->

**When:** `*Handler.java`, `*Router.java`, `*Service.java` in reactive packages, any `Mono`/`Flux` usage, R2DBC repositories, `TransactionalOperator`.

---

## DO

### Threading & blocking
- **Never** call `.block()`, `.blockFirst()`, `.blockLast()` on the event-loop thread — it deadlocks or starves the server.
- Wrap legacy/blocking I/O with `Mono.fromCallable` + `subscribeOn(Schedulers.boundedElastic())` — place `subscribeOn` **immediately after the source**.
- Use `publishOn(scheduler)` to shift downstream processing (e.g. CPU-heavy transforms); use `subscribeOn` only to shift the source subscription.

### Assembly vs subscription
- **Propagate, don't subscribe**: return `Mono`/`Flux` up the call stack. Never call `.subscribe()` inside a handler or service — Spring/WebFlux subscribes for you.
- Compose with `flatMap`/`then`/`zip`; side effects go in `doOnNext`/`doOnError`/`doFinally`.

### Error handling
- Use `onErrorResume` to recover with a fallback publisher (cache, default, retry).
- Use `onErrorMap` to translate low-level exceptions into domain exceptions — always wrap the original as the cause.
- Use `onErrorReturn` only for simple scalar fallbacks.
- Errors propagate to the subscriber; **do not swallow** them with empty `onErrorResume(e -> Mono.empty())` unless intentional.

### Router / Handler (preferred over `@RestController`)
- Return `Mono<ServerResponse>` from every handler method.
- Use `RouterFunctions.route()` builder with `GET/POST/PUT/DELETE` + `accept()` predicates.
- Apply cross-cutting logic (auth, logging) via `RouterFunction.filter(HandlerFilterFunction)`.

### R2DBC entities & repositories
- Annotate with `@Table`, `@Id`, `@Column` (Spring Data R2DBC) — **never** JPA annotations (`@Entity`, `@OneToMany`).
- Prefer Java `record` for entities; add `@CreatedDate`/`@LastModifiedDate`/`@Version` for auditing.
- Extend `R2dbcRepository<T, ID>`; custom queries via `@Query`.
- Use `R2dbcEntityTemplate` for dynamic criteria (`Query`/`Criteria` DSL).
- **Manual joins** only — R2DBC has no lazy-loading or cascade. Load associations with `flatMap`/`zip`.

### Transactions
- Inject `TransactionalOperator`; wrap multi-statement operations with `tx.transactional(flux)`.
- `@Transactional` on reactive methods works in Spring Boot 3.2+ but `TransactionalOperator` is explicit and testable.

### Backpressure
- Add `.limitRate(N)` on database `Flux` results and streaming endpoints — request in bounded batches.
- For hot publishers (Sinks, Kafka, SSE): use `.onBackpressureBuffer(size, strategy)` with an explicit strategy (`DROP_OLDEST`, `DROP_LATEST`, `ERROR`).
- Cap `flatMap` concurrency: `flatMap(fn, 16)` — default is unbounded and can exhaust the connection pool.
- Use `concatMap` when order must be preserved (concurrency = 1); `flatMapSequential` for ordered + concurrent.

### Reactor Context
- Write context downstream (bottom of chain) with `contextWrite(ctx -> ctx.put(key, value))`.
- Read upstream with `Mono.deferContextual(ctx -> ...)` — context flows **up** the assembly chain (reads see writes placed **after** them in source order).
- Propagate security/trace metadata via Context rather than `ThreadLocal`.

### Testing
- Use `StepVerifier.create(publisher).expectNext(...).verifyComplete()` — never `.block()` in tests.
- Enable BlockHound (`BlockHound.install()` in `@BeforeAll`) to fail the test suite if a blocking call lands on a reactive thread.
- Use `WebTestClient` for handler integration tests.

---

## DON'T

- `.block()` / `.blockFirst()` / `.blockLast()` anywhere in a production reactive chain.
- `Thread.sleep()` inside an operator — use `Mono.delay` or `delayElements`.
- Synchronous I/O (JDBC, `RestTemplate`, `FileReader`) without `subscribeOn(boundedElastic)`.
- `.subscribe(...)` inside a handler or service — causes fire-and-forget, context loss, and error swallowing.
- `@OneToMany`, `@JoinColumn`, `@Entity` on R2DBC entities.
- `Mono.fromCallable + subscribeOn(boundedElastic)` for R2DBC operations — they are already reactive; adding a scheduler wraps them unnecessarily.
- `subscribeOn(Schedulers.parallel())` for blocking work — parallel pool is for CPU, not blocking I/O.
- Unbounded `flatMap` on a large `Flux` — always pass a concurrency cap.
- `Sinks.many().multicast()` without `.onBackpressureBuffer(size, false)` — unbounded buffer → OOM under slow consumers.
- `contextWrite` above the read site — context propagates upward, not downward.

---

## Correct example

```java
// Router
@Configuration
public class UserRouter {
    @Bean
    public RouterFunction<ServerResponse> userRoutes(UserHandler handler) {
        return RouterFunctions.route()
            .GET("/users/{id}", accept(APPLICATION_JSON), handler::getById)
            .POST("/users",     accept(APPLICATION_JSON), handler::create)
            .build();
    }
}

// Handler
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

    public Mono<ServerResponse> create(ServerRequest req) {
        return req.bodyToMono(CreateUserRequest.class)
            .flatMap(service::create)
            .flatMap(user -> ServerResponse.created(URI.create("/users/" + user.id()))
                                           .bodyValue(user));
    }
}

// Entity + Repository
@Table("users")
public record User(
    @Id UUID id,
    String email,
    String name,
    @CreatedDate Instant createdAt,
    @Version Long version
) {}

@Repository
public interface UserRepository extends R2dbcRepository<User, UUID> {
    Mono<User> findByEmail(String email);

    @Query("SELECT * FROM users WHERE active = true ORDER BY created_at DESC LIMIT :limit")
    Flux<User> findActive(@Param("limit") int limit);
}

// Service with TransactionalOperator + manual join
@Service
@RequiredArgsConstructor
public class UserService {
    private final UserRepository userRepo;
    private final ProfileRepository profileRepo;
    private final TransactionalOperator tx;

    public Mono<User> findById(UUID id) {
        return userRepo.findById(id);
    }

    public Mono<UserWithProfile> findWithProfile(UUID id) {
        return Mono.zip(
            userRepo.findById(id).switchIfEmpty(Mono.error(new NotFoundException(id))),
            profileRepo.findByUserId(id).defaultIfEmpty(Profile.empty())
        ).map(t -> new UserWithProfile(t.getT1(), t.getT2()));
    }

    public Mono<User> create(CreateUserRequest req) {
        User user = new User(UUID.randomUUID(), req.email(), req.name(), null, null);
        Profile profile = Profile.defaultFor(user.id());
        return tx.transactional(
            userRepo.save(user)
                .flatMap(saved -> profileRepo.save(profile).thenReturn(saved))
        );
    }
}

// Wrapping a blocking legacy call
public Mono<Report> generateReport(UUID id) {
    return Mono.fromCallable(() -> legacyReportService.generate(id))   // blocking
               .subscribeOn(Schedulers.boundedElastic());               // offload thread
}

// Backpressure on streaming endpoint
@GetMapping(value = "/users/stream", produces = TEXT_EVENT_STREAM_VALUE)
public Flux<User> stream() {
    return userRepo.findActive(10_000)
        .limitRate(200)                           // fetch DB rows in batches of 200
        .flatMap(this::enrichAsync, 16);          // max 16 concurrent enrich calls
}

// Reactor Context for trace propagation
public Mono<User> findByIdWithTrace(UUID id) {
    return Mono.deferContextual(ctx -> {
        String traceId = ctx.getOrDefault("traceId", "none");
        log.debug("findById traceId={}", traceId);
        return userRepo.findById(id);
    });
}
```

---

## Anti-pattern

```java
// BLOCKS the Netty event-loop thread — server hangs under load
public Mono<ServerResponse> getById(ServerRequest req) {
    User user = service.findById(UUID.fromString(req.pathVariable("id"))).block(); // BAD
    return ServerResponse.ok().bodyValue(user);
}

// Subscribes inside a handler — fire-and-forget, errors swallowed, context lost
public Mono<ServerResponse> create(ServerRequest req) {
    req.bodyToMono(CreateUserRequest.class)
       .flatMap(service::create)
       .subscribe();  // BAD — Spring never sees the result
    return ServerResponse.ok().build();
}

// JPA annotation on R2DBC entity — not supported, causes runtime failure
@Entity                   // BAD
public class Order {
    @OneToMany            // BAD
    private List<Item> items;
}

// Unbounded flatMap — exhausts connection pool
Flux.fromIterable(thousandsOfIds)
    .flatMap(userRepo::findById)   // BAD — no concurrency cap
    .collectList();

// Blocking call on parallel scheduler — wrong pool, blocks CPU threads
Mono.fromCallable(() -> legacyService.fetch(id))
    .subscribeOn(Schedulers.parallel());  // BAD — use boundedElastic
```

---

## Gotchas / version notes

| Topic | Note |
|---|---|
| `contextWrite` direction | Flows **up** the assembly chain. Write it at the bottom; reads placed above will see it. |
| `subscribeOn` placement | Only the first `subscribeOn` in a chain takes effect for the source. Put it directly after `Mono.fromCallable`. |
| `publishOn` vs `subscribeOn` | `publishOn` switches the thread for **downstream** operators; `subscribeOn` switches the **source** subscription thread. |
| `flatMap` concurrency | Default is `Queues.SMALL_BUFFER_SIZE` (256 in-flight). Always pass explicit cap for DB/HTTP calls. |
| `@Transactional` on reactive | Works in Spring Boot 3.2+ with `ReactiveTransactionManager`. Prefer `TransactionalOperator` for explicit control and easier testing. |
| R2DBC pool sizing | Default `r2dbc-pool` initial=10, max=10. Tune `spring.r2dbc.pool.max-size` to match `flatMap` concurrency cap. |
| `Sinks.many().unicast()` | Only one subscriber allowed; throws on second subscribe. Use `multicast()` for multiple subscribers. |
| BlockHound | Must call `BlockHound.install()` before the first reactive subscription in the test JVM. Use `@BeforeAll static` or a JUnit 5 extension. |
| `record` entities | R2DBC 3.x supports `record` via `@PersistenceCreator` on the canonical constructor (auto-detected in Spring Boot 3.2+). |
| `deferContextual` vs `transformDeferredContextual` | For operator-level context access, use `transformDeferredContextual`; for value-level, use `Mono.deferContextual`. |
