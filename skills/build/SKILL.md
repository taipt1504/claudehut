---
name: build
description: Phase 4 of ClaudeHut workflow — execute the approved plan task-by-task with strict TDD (RED → GREEN → REFACTOR). Touches only files listed in the plan (surgical scope). One commit per task. Use after Plan phase approval. Triggers when phase=build.
---

# Build — Phase 4

Execute the plan with strict TDD discipline. The ONLY phase where production code is written.

## Quick start

For each unchecked task in `.claudehut/plans/<id>-plan.md`:

1. Load the task block. The PreToolUse hook will auto-inject matching tech-stack rules by file pattern.
2. **RED.** Write the failing test. Run RED command — must FAIL with expected error.
3. **GREEN.** Write minimal code. Run verify command — must PASS.
4. **REFACTOR.** Optional. Improve naming/structure without changing behavior. Tests must still pass.
5. Commit per task using Conventional Commits.
6. Check off the task in the plan.

## Hard rules

- SURGICAL SCOPE: only touch files in the current task's `create:` / `modify:` / `test:`.
- RED MUST fail with the expected error type/message. If it passes immediately, DELETE the test and restart.
- NEVER use "reference code" while writing tests — that's test-after.
- ONE commit per task. Conventional Commits format.

Detailed TDD anti-patterns: `references/red-green-refactor.md`. Surgical scope enforcement: `references/surgical-scope-rules.md`. Commit conventions: `references/commit-convention.md`.

## Per-file pattern rule loading

The PreToolUse hook auto-loads matching rules:

| File pattern | Rule loaded |
|--------------|-------------|
| `**/*Controller.java` (mvc) | `rules/framework/spring-mvc.md` |
| `**/*Handler.java` (webflux) | `rules/framework/webflux.md` |
| `**/*Repository.java` (jpa) | `rules/framework/jpa.md` |
| `**/*Repository.java` (r2dbc) | `rules/framework/r2dbc.md` |
| `**/*Mapper.java` | `rules/framework/mapstruct.md` |
| `**/*{Dto,Request,Response}.java` | `rules/framework/jackson.md` |
| `**/db/migration/V*.sql` | `rules/framework/migration-safety.md` |
| `**/*Listener*.java` (kafka) | `rules/framework/kafka-consumer.md` |

## Scripts

- `scripts/pre-write-scope-check.sh <file>` — verify file is in current task's allowed scope (called by PreToolUse).

## Exit criteria

- [ ] Every task in plan checked ✓
- [ ] `./gradlew check` (or Maven `verify`) passes locally
- [ ] No surgical-scope violations recorded
- [ ] Phase advanced to `loop`
