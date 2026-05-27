# Verify Gates

## Default thresholds

| Gate | Command (Gradle) | Threshold |
|------|------------------|-----------|
| Build | `./gradlew compileJava compileTestJava` | no error |
| Unit tests | `./gradlew test` | 100% pass, 0 skip |
| Integration | `./gradlew integrationTest` | 100% pass |
| Coverage line | `./gradlew jacocoTestReport jacocoTestCoverageVerification` | ≥ `coverage.line_threshold` (default 0.80) |
| Coverage branch | (same) | ≥ `coverage.branch_threshold` (default 0.70) |
| Lint | `./gradlew spotlessCheck checkstyleMain` | error severity = 0 |
| Static SpotBugs | `./gradlew spotbugsMain` | medium+ = 0 |
| Static PMD | `./gradlew pmdMain` | medium+ = 0 |
| OWASP deps | `./gradlew dependencyCheckAnalyze` | High + Critical = 0 |
| Perf smoke (optional) | Gatling/JMH | no regression > 10% |

## Maven equivalents

| Gradle command | Maven equivalent |
|----------------|------------------|
| `./gradlew compileJava compileTestJava` | `mvn test-compile` |
| `./gradlew test` | `mvn test` |
| `./gradlew integrationTest` | `mvn verify -DskipITs=false` |
| `./gradlew jacocoTestReport` | `mvn verify` (with jacoco-maven-plugin) |
| `./gradlew spotlessCheck` | `mvn spotless:check` |
| `./gradlew spotbugsMain` | `mvn spotbugs:check` |
| `./gradlew pmdMain` | `mvn pmd:check` |
| `./gradlew dependencyCheckAnalyze` | `mvn dependency-check:check` |

## Selecting which gates to run

- If a tool is not configured in the build, the gate is skipped (not failed).
- `claudehut-config.json#mcp_servers_enabled` does not affect verify gates.
- Project-specific gates can be added via project hook in `.claude/settings.json#hooks.PostToolUse`.

## Parallelization

These can run in parallel (independent inputs/outputs):
- Lint + Static + Coverage report
- All review subagents

Sequential (depends on prior):
- Compile → Test → Coverage report

## Output format

Each gate writes a stanza into `findings.json`:

```json
{
  "verify": {
    "build": {"status": "pass"},
    "test": {"status": "pass", "passed": 142, "failed": 0, "skipped": 0},
    "coverage": {"status": "pass", "line": 0.842, "branch": 0.713},
    "lint": {"status": "pass", "errors": 0},
    "static": {"status": "pass", "medium": 0, "high": 0},
    "security": {"status": "pass", "critical": 0, "high": 0}
  }
}
```
