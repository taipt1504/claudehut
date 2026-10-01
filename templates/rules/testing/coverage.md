---
id: rules/testing/coverage
paths:
  - "**/*Test.java"
  - "**/*Tests.java"
severity: medium
tags: [coverage, jacoco]
---
<!-- ClaudeHut rule template — generated into .claude/rules/testing/coverage.md by claudehut-init. -->


# Coverage Thresholds

## Defaults

- **Line coverage:** ≥ 80% (set in the build's JaCoCo verification rule).
- **Branch coverage:** ≥ 70% (same rule, `BRANCH` counter).

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

## Enforcement

When the verify command in `.claude/claudehut/PROJECT.md` runs `jacocoTestCoverageVerification` (Gradle) or
`jacoco:check` (Maven), a threshold miss is a failing test result in the evidence Review records.
