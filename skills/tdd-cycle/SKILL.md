---
name: tdd-cycle
description: Enforce strict RED -> GREEN -> REFACTOR for Java/Spring code; required for every Build task. Detects and rejects anti-patterns (prod-before-test, test-after, manual-test rationalization). Invoke during Phase 4 Build or whenever writing new logic.
---

# TDD Cycle

Strict RED → GREEN → REFACTOR. Non-negotiable per task in Build phase.

## Quick start

For each new behavior:

1. **RED.** Write ONE failing test. Run it. Verify it FAILS for the right reason.
2. **GREEN.** Write minimum production code. Run target test + neighbours. All pass.
3. **REFACTOR.** Optional. Improve without changing behavior. Tests still pass identically.
4. Commit per cycle.

Detailed: `references/red-green-refactor.md`. Anti-patterns + recovery: `references/anti-patterns.md`. Worked examples: `references/examples.md`.

## Scripts

- `scripts/watch-test-fail.sh <gradle-spec>` — runs test command; exits 0 ONLY if test FAILED (RED verification).

## Hard rules

- Test FIRST. Always. No "draft impl while I write the test".
- Verify RED → DELETE the test if it passes immediately. You're testing existing behavior, not new.
- GREEN = minimum. No anticipatory features.
- REFACTOR doesn't change behavior. Tests stay identical pre/post.

## Stack-specific cheat sheet

| Stack | Test pattern |
|-------|--------------|
| Spring MVC | `@WebMvcTest(UserController.class)` + `MockMvc.perform(...)` |
| Spring WebFlux | `@WebFluxTest(UserHandler.class)` + `WebTestClient.get()...` |
| JPA | `@DataJpaTest` + Testcontainers Postgres |
| R2DBC | `@DataR2dbcTest` + Testcontainers Postgres |
| Service unit | `@ExtendWith(MockitoExtension.class)` + `@InjectMocks` |
| Reactive logic | `StepVerifier.create(mono).expectNext(...).verifyComplete()` |
| Kafka | Testcontainers `KafkaContainer` + embedded producer/consumer |
| HTTP client | WireMock stub under `src/test/resources/__stubs/` |

## Exit criteria

- [ ] Failing test committed first
- [ ] Implementation makes test pass
- [ ] Neighbours still green
- [ ] One commit per cycle
