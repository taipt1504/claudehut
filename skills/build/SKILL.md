---
name: build
description: Phase 4 of ClaudeHut workflow — execute the approved plan by dispatching each parallel group of tasks as concurrent builder subagents (each in its own git worktree), then merging results. Tasks within the same Parallel group run simultaneously; groups run in order. Strict TDD enforced per task. Use after Plan phase approval. Triggers when phase=build.
---

## Dispatch contract (read this FIRST)

This phase executes parallel groups via **`scripts/run-parallel-group.sh`** — one `claude --print` process per task, each in an isolated git worktree. Concurrency is guaranteed at the OS level; the script handles worktree lifecycle, result parsing, and merge-back automatically.

### Parallel-group execution loop

```
PLAN    = .claudehut/plans/<task-id>-plan.md
TASK_ID = claudehut-state task-id
GROUPS  = sorted distinct "Parallel group:" values in PLAN (1, 2, 3 …)

for G in GROUPS:
  Run: scripts/run-parallel-group.sh "$ARGUMENTS" TASK_ID PLAN G
  # subagent_type = "claudehut-builder"  (each worker follows builder instructions)
  Exit 0 → proceed to next group
  Exit 1 → surface failures to user; await decision

After last group:
  ./gradlew check  (or mvn verify)
  Advance phase to loop
```

`run-parallel-group.sh` creates git worktrees, launches parallel `claude --print` processes, waits for all, parses `claudehut-builder-result` blocks, and calls `merge-parallel-group.sh` for passing tasks.

---

# Build — Phase 4

Execute the plan with strict TDD discipline. The ONLY phase where production code is written.

## Quick start

1. Read `.claudehut/plans/<id>-plan.md`. Extract all distinct `Parallel group:` values.
2. For each group G in order: run `scripts/run-parallel-group.sh "$ARGUMENTS" <task-id> <plan-file> G`.
3. On non-zero exit: surface failures to user; await decision before next group.
4. After last group: `./gradlew check`; advance phase to `loop`.

Each builder process handles its task autonomously (RED → GREEN → REFACTOR → commit → emit result).

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

- `scripts/run-parallel-group.sh "<user-intent>" <task-id> <plan-file> <group-num>` — dispatch all unchecked tasks in a parallel group as concurrent `claude --print` processes; merges passing branches automatically.
- `scripts/dispatch-prompt.sh "<user-intent>" <task-num>` — generate a single-task builder prompt (task-num selects which plan task block to include).
- `scripts/merge-parallel-group.sh <task-id> <plan-file> [task-num:branch ...]` — cherry-pick each worktree branch onto main and tick plan checkboxes.
- `scripts/pre-write-scope-check.sh <file>` — verify file is in current task's allowed scope (called by PreToolUse).

## Exit criteria

- [ ] Every task in plan checked ✓
- [ ] `./gradlew check` (or Maven `verify`) passes locally
- [ ] No surgical-scope violations recorded
- [ ] Phase advanced to `loop`
