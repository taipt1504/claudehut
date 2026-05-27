---
id: rules/testing/tdd-cycle
applies-to: "**/*Test.java"
severity: high
tags: [tdd, testing, red-green-refactor]
---

# TDD Cycle — RED → GREEN → REFACTOR

## RED

1. Write ONE failing test before any production code.
2. Run the test. **Verify it fails** with expected error type.
3. If it passes immediately → DELETE; the test asserts existing behavior, not new.
4. If it fails for the wrong reason (setup error) → fix the test, not the prod code.

## GREEN

1. Write the **minimum** code to pass the test.
2. Resist anticipatory features. No "while we're here".
3. Verify all tests pass (target + neighbours).
4. Output must be clean — no new warnings from neighbour tests.

## REFACTOR (optional)

1. Only if green.
2. Improve naming, extract helpers, dedupe.
3. Do NOT change behavior. Tests still pass identically.

## Blocked anti-patterns

| Anti-pattern | Recovery |
|--------------|----------|
| Prod code before failing test | Delete code; start RED |
| Test passes immediately on first RED | Delete test; ensure it asserts new behavior |
| Using "reference code" while writing test | Delete; write test from contract |
| Manual test "just this once" | Add automated test |
| Skip fail-verification step | Restart from RED |
| Rationalize: "just this once" | No exceptions |

## Behavioral signals

### Clean RED

```
Tests: 12, Failures: 1, Errors: 0
- shouldRejectDuplicate:
    Expected: thrown DuplicateException
    Actual:   no exception thrown
```

### Dirty RED (means fix the test setup, not write prod code)

```
Tests: 12, Failures: 0, Errors: 1
- shouldRejectDuplicate:
    NullPointerException at FooServiceTest.setup line 23
```

## Coverage expectation

- New code: 100% line coverage for the new test.
- Aggregate: line ≥ 0.80, branch ≥ 0.70 (configurable in `claudehut-config.json#coverage`).

## Stack-specific

| Stack | Test pattern |
|-------|--------------|
| Spring MVC | `@WebMvcTest(UserController.class)` + `MockMvc` |
| Spring WebFlux | `@WebFluxTest(UserHandler.class)` + `WebTestClient` |
| JPA | `@DataJpaTest` + Testcontainers |
| R2DBC | `@DataR2dbcTest` + Testcontainers |
| Kafka | Testcontainers `KafkaContainer` + `KafkaTemplate` |
| External HTTP | WireMock stub under `src/test/resources/__stubs/` |

## Per-task commit

ONE commit per RED→GREEN cycle. Conventional Commits:

```
feat(user): reject duplicate on create

Closes test shouldRejectDuplicate.
```
