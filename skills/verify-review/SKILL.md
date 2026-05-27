---
name: verify-review
description: Phase 5 of ClaudeHut workflow — run verify pipeline (build/tests/coverage/lint/static/security) then dispatch reviewer subagents in parallel; aggregate findings; pass-or-refactor decision; bounded retry (max 3) then escalate. Use after Build phase completes. Triggers when phase=loop.
---

# Verify-Review — Phase 5 (Loop)

Quality gate that may iterate. Each iteration either passes (→ Learn) or injects a refactor task back to Build.

## Quick start

1. **Verify stage** (parallel where possible) — `scripts/run-verify-parallel.sh`.
2. **Review stage** — dispatch 5–6 reviewer subagents in parallel (one message, multiple Task invocations).
3. **Aggregate** — `scripts/aggregate-findings.sh` writes `state/tasks/<id>/findings.json`.
4. **Decide:**
   - 0 Critical AND 0 High → PASS. Advance to Learn.
   - ≥ 1 Critical OR ≥ 3 High → FAIL. Inject refactor task. Retry++.
   - Retry == 3 → ESCALATE to user.

## Verify gates

Detailed gates + thresholds: `references/verify-gates.md`.

| Gate | Block-on |
|------|----------|
| Build | any compile error |
| Unit tests | fail/skip |
| Integration tests | fail |
| Coverage | line < threshold (config) |
| Lint (Spotless/Checkstyle) | error severity |
| Static (SpotBugs/PMD/SonarLint) | medium+ |
| OWASP dependency-check | High/Critical |

## Review subagents (parallel)

Detailed reviewer roster: `references/reviewer-dispatch.md`.

- `claudehut-reviewer-security`
- `claudehut-reviewer-perf`
- `claudehut-reviewer-db`
- `claudehut-reviewer-reactive` (skip if web_stack ≠ webflux)
- `claudehut-reviewer-style`
- `claudehut-reviewer-mapping` (skip if no MapStruct/Jackson involved)

Spawn in ONE message with multiple subagent invocations — never serialize.

## Decision logic

Detailed retry/escalation: `references/retry-escalation.md`.

```
verify_pass = all gates green
review_clean = critical == 0 AND high < 3
if verify_pass AND review_clean:
    advance to "learn"
else:
    retry++
    if retry < 3:
        inject refactor task into plan
        return to "build"
    else:
        escalate to user with full findings
```

## Scripts

- `scripts/run-verify-parallel.sh` — invokes Gradle/Maven gates in parallel.
- `scripts/aggregate-findings.sh` — merges reviewer findings into single JSON.

## Assets

- `assets/templates/findings-report.md.tmpl` — human-readable findings summary.

## Exit criteria

- [ ] All verify gates green
- [ ] 0 Critical + < 3 High findings
- [ ] findings.json persisted
- [ ] Phase advanced to `learn`
