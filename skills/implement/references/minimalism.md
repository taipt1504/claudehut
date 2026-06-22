# Minimalism — the lazy-senior-dev decision ladder (Spring/Java) — best-practice playbook
<!-- claudehut: preloaded via claudehut:implement; create-time guidance. Distilled from the ponytail
     plugin's "best code is the code you never wrote" decision ladder, adapted to Spring Boot 3.x / Java 17+.
     Pairs with the Discover necessity+framework-first scan — this file is the create-time "what the
     framework already gives you" reference. Less code written = fewer defects + fewer tokens. -->

**When:** about to write ANY new production code — before the RED test, settle which rung you are on.

## The ladder — stop at the first rung that applies

```
0. Does this need to exist?        → it doesn't: DROP it (YAGNI). The cheapest code is none.
1. Does the JDK / Java stdlib do it? → use it (java.util, java.time, java.net.http, Stream, Optional…).
2. Does Spring / an installed starter do it? → use it (see the table below).
3. Does an already-declared dependency do it? → use it (check build.gradle / pom.xml first).
4. Is it one expression?            → one line. No class, no interface, no factory.
5. Only then:                        → the MINIMUM viable implementation. Nothing speculative.
```

**The ladder is a reflex, not a research project.** Two rungs work → take the higher one and move on; the
first lazy solution that works is the right one. Don't turn "is there a framework feature?" into a 20-minute
survey — a quick classpath/stdlib check, then build. (Over-analyzing the ladder is itself the waste it exists
to kill.) The Discover reuse-scan settles rungs 0–3 with an artifact; this playbook is the create-time
reminder of *what* rungs 1–2 already give you in Spring so you don't hand-roll it.

## The safety floor — NEVER on the chopping block

Minimalism cuts **unnecessary complexity**, never **necessary robustness**. These are never "simplified away":
**input validation, error handling, security/authz, transaction correctness, observability.** Dropping a
`@Valid`, a deny-by-default rule, a rollback boundary, or a null-guard is not "lazy" — it is a defect. If a rung
tempts you to cut one of these, you are on the wrong rung.

## DON'T hand-roll — Spring/Java already ships it

| Hand-rolling… | Use instead (rung) | Note |
|---|---|---|
| retry loops / `Thread.sleep` backoff | **Spring Retry** `@Retryable`/`@Recover`, or **Resilience4j** `@Retry` (2) | Resilience4j also gives `@CircuitBreaker`, `@RateLimiter`, `@Bulkhead`, `@TimeLimiter` |
| token-bucket / sliding-window rate limiter | **Resilience4j `@RateLimiter`** or **bucket4j** (2/3) | the measured miss — a rate-limit task hand-built what a dep provides |
| `ConcurrentHashMap` as a cache | **Spring Cache** `@Cacheable`/`@CacheEvict` + Caffeine/Redis (2) | declarative, with TTL/eviction; don't reinvent expiry |
| `ExecutorService`/`Timer`/`new Thread` for periodic work | **`@Scheduled`** / `TaskScheduler` (2) | fixed-rate/cron, lifecycle-managed |
| manual thread pool for fire-and-forget | **`@Async`** + `CompletableFuture` (2) | servlet stacks only — never inside a reactive chain |
| manual null/format/range checks in controllers | **Bean Validation** `@Valid` + `@NotNull`/`@Email`/`@Size`/`@Pattern`, custom `ConstraintValidator` (2) | declarative; floor item — validate, don't skip |
| DTO ↔ entity copy code | **MapStruct** (3) | compile-time, no reflection; see `java-lang.md` |
| `RestTemplate`/`HttpURLConnection` boilerplate | **declarative HTTP interface** `@HttpExchange` + `RestClient`/`WebClient` proxy, or **OpenFeign** (2/3) | one interface, no plumbing |
| `System.getenv`/`Properties` parsing | **`@ConfigurationProperties`** / `@Value` + profiles (2) | typed, validated, externalized |
| hand-written SQL paging / sorting / dynamic where | **Spring Data** `Pageable`, derived queries, `@Query`, `Specification`/QueryDSL (2) | don't string-build SQL |
| try/catch → HTTP status in every controller | **`@RestControllerAdvice`** + `@ExceptionHandler` + **`ProblemDetail`** (RFC 7807) (2) | centralized; floor item — handle errors, don't swallow |
| observer pattern / manual callback list | **`ApplicationEventPublisher`** + `@EventListener`/`@TransactionalEventListener` (2) | in-process events for free |
| manual commit/rollback | **`@Transactional`** on the service (2) | services own the boundary |
| `new`-ing collaborators / bespoke factories | **constructor injection** (2) | the container is the factory |
| custom JSON parsing | **Jackson** `ObjectMapper`/`@JsonView` (2) | auto-configured |
| bespoke `/health`, metrics counters | **Actuator** + **Micrometer** (2) | floor item — observability, free |
| getters/setters/builder boilerplate on DTOs | **`record`**, else Lombok (1) | never `@Data`/`@Builder` on `@Entity` (see `jpa.md`) |

## DON'T over-engineer — speculative complexity to cut

- **Single-implementation interface** "for testing/flexibility." Spring mocks concrete classes; add the interface
  when the *second* implementation arrives, not before.
- **Generics / type parameters** a caller never varies. Concrete first.
- **Config knobs / strategy patterns / feature flags** nobody asked for. YAGNI — the request defines the scope.
- **A new utility class** for a one-liner that lives fine inline (rung 4).
- **An abstraction layer** wrapping a framework that is already an abstraction (a `CacheService` over `@Cacheable`,
  a `RepositoryFacade` over a Spring Data repo).
- **Defensive handling for impossible states** — a branch for input the type system already forbids.
- **Re-exporting / re-wrapping** a stdlib type to "decouple" from it.

## Red flags — STOP

- Writing a loop/class/interface whose job a table row above names. Use the framework feature.
- "I'll make it configurable/generic so it's flexible later." That later rarely comes; the complexity ships now.
- Justifying a new abstraction with a single current caller.
- Cutting a floor item (validation/error/security/tx/observability) and calling it minimalism. It is a defect.
