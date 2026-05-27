---
id: rules/testing/coverage
paths:
  - "**/*Test.java"
severity: medium
tags: [coverage, jacoco]
---


# Coverage Thresholds

## Defaults

- **Line coverage:** ≥ 80% (configurable via `claudehut-config.json#coverage.line_threshold`).
- **Branch coverage:** ≥ 70% (configurable via `coverage.branch_threshold`).

## Per-class threshold

Some classes can have higher bar:

- **Domain logic** (`domain/**`): ≥ 95% line.
- **Service layer**: ≥ 85% line.
- **Controllers/Handlers**: ≥ 80% line.
- **Mappers (MapStruct generated)**: excluded from coverage (annotation-generated).
- **Configuration classes**: ≥ 60% (most paths execute on startup).
- **DTOs / records**: excluded (data carriers, no logic).

## Excluded paths

In `build.gradle.kts`:

```kotlin
jacocoTestCoverageVerification {
  violationRules {
    rule {
      element = "CLASS"
      excludes = listOf(
        "*.dto.*",
        "*.config.*",
        "*Mapper",
        "*MapperImpl",     // MapStruct generated
        "*Application"     // Spring Boot main
      )
      limit { minimum = "0.80".toBigDecimal() }
    }
  }
}
```

## Branch coverage

More important than line for:

- `if`/`else` decision logic
- `switch` statements
- ternary expressions
- exception handling paths

Don't game branch coverage by removing legitimate `if` checks just to pass.

## When coverage is hard

| Hard to cover | Strategy |
|---------------|----------|
| Constructor edge cases | Use parameterized tests |
| Private methods | Don't test directly — test via public surface |
| Defensive null checks | Test or remove (often dead code) |
| Logging statements | Acceptable to skip (excluded by default) |
| Generated code | Add to excludes |

## Coverage anti-patterns

- Writing tests that only assert "no exception thrown" — bumps coverage, tests nothing.
- Reflective tests to hit private fields — fragile, false signal.
- Setting threshold to 100% — leads to game-the-metric tests.
- Excluding too aggressively — defeats the purpose.

## Gate enforcement

Phase 5 verify gate runs `./gradlew jacocoTestCoverageVerification`. Fail blocks promotion to Learn.
