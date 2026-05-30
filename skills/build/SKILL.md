---
name: build
description: Phase 4 of ClaudeHut workflow — execute the approved plan by dispatching each parallel group of tasks as concurrent builder subagents (each in its own git worktree), then merging results. Tasks within the same Parallel group run simultaneously; groups run in order. Strict TDD enforced per task. Use after Plan phase approval. Triggers when phase=build.
---

## Dispatch contract (read this FIRST)

This phase executes parallel groups via **`scripts/run-parallel-group.sh`** — one `claude --print` process per task, each in an isolated git worktree. Workers are FULL headless sessions (not Agent-tool subagents), so they load skills/hooks normally; persona guardrails are injected via `--append-system-prompt` and the model is pinned to `sonnet` for cost. Concurrency is guaranteed at the OS level; the script handles worktree lifecycle, result parsing, merge-back, and the per-group gate automatically.

### Parallel-group execution loop

```
PLAN    = .claudehut/plans/<task-id>-plan.md
TASK_ID = claudehut-state task-id
GROUPS  = sorted distinct "Parallel group:" values in PLAN (1, 2, 3 …)

# ── Stub step (sequential, ONCE before any group) ─────────────────────
# Scaffold compiling skeletons for every type/signature the plan introduces,
# committed to the branch. Workers branch from this commit, so they cannot
# invent divergent signatures (drift), reference a missing type (hidden dep),
# or merge-then-break (semantic conflict).
Run: scripts/scaffold-stubs.sh "$ARGUMENTS" TASK_ID
  Exit 1 (stubs do not compile) → surface to user; STOP

# ── Group loop ────────────────────────────────────────────────────────
for G in GROUPS:
  Run: scripts/run-parallel-group.sh "$ARGUMENTS" TASK_ID PLAN G
  # subagent_type = "claudehut:claudehut-builder"  (each worker follows builder instructions)
  # script merges passing branches, then runs a per-group compile+test gate
  Exit 0 → proceed to next group
  Exit 1 → surface failures (worker fail OR gate fail) to user; await decision
  Exit 3 → BUDGET HALT (worker pool, Phase 5.1): read .claudehut/state/budget-breach.json
           and surface spend_usd / cap_usd / tasks_unstarted to the user; do NOT retry the
           group. Committed work from prior groups is preserved. Raising
           budget.max_worker_pool_usd (or routing quick) is the remedy.

After last group:
  ./gradlew check  (or mvn verify)
  Advance phase to loop
```

`scaffold-stubs.sh` runs once: generates + commits compiling stubs from `contract.md` + plan.
`run-parallel-group.sh` per group: creates worktrees, launches parallel `claude --print` workers, waits, parses `claudehut-builder-result` blocks, merges passing tasks, then gates on compile+test before returning.

---

# Build — Phase 4

Execute the plan with strict TDD discipline. The ONLY phase where production code is written.

## Quick start

1. Read `.claudehut/plans/<id>-plan.md`. Extract all distinct `Parallel group:` values.
2. Run `scripts/scaffold-stubs.sh "$ARGUMENTS" <task-id>` once. Non-zero exit → stop, surface.
3. For each group G in order: run `scripts/run-parallel-group.sh "$ARGUMENTS" <task-id> <plan-file> G`.
4. On non-zero exit (worker fail or per-group gate fail): surface failures; await decision before next group.
5. After last group: `./gradlew check`; advance phase to `loop`.

Each builder process handles its task autonomously (RED → GREEN → REFACTOR → commit → emit result), branching from the stub commit.

## Hard rules

- SURGICAL SCOPE: only touch files in the current task's `create:` / `modify:` / `test:`.
- RED MUST fail with the expected error type/message. If it passes immediately, DELETE the test and restart.
- NEVER use "reference code" while writing tests — that's test-after.
- ONE commit per task. Conventional Commits format.

Detailed TDD anti-patterns: `references/red-green-refactor.md`. Surgical scope enforcement: `references/surgical-scope-rules.md`. Commit conventions: `references/commit-convention.md`. Parallel-build mechanism + verification record: `references/parallel-build-verification.md`.

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

- `scripts/scaffold-stubs.sh "<user-intent>" <task-id>` — sequential pre-build step; generate + commit compiling stubs from contract + plan so parallel workers branch from real types.
- `scripts/run-parallel-group.sh "<user-intent>" <task-id> <plan-file> <group-num>` — dispatch all unchecked tasks in a parallel group as concurrent `claude --print` processes; merges passing branches and runs a per-group compile+test gate. Tunables: `CLAUDEHUT_WORKER_MODEL` (default sonnet), `CLAUDEHUT_TASK_TIMEOUT` (default 900s).
- `scripts/dispatch-prompt.sh "<user-intent>" <task-num>` — generate a single-task builder prompt (task-num selects which plan task block to include).
- `scripts/merge-parallel-group.sh <task-id> <plan-file> [task-num:branch ...]` — cherry-pick each worktree branch onto main and tick plan checkboxes.
- Surgical-scope enforcement is inline in the wired PreToolUse hook (`hooks/pre-tool.sh`); it denies Write/Edit of files not in the current task's plan. (`scripts/pre-write-scope-check.sh` is a legacy standalone of the same logic, not wired.)

## Exit criteria

- [ ] Every task in plan checked ✓
- [ ] `./gradlew check` (or Maven `verify`) passes locally
- [ ] No surgical-scope violations recorded
- [ ] Phase advanced to `loop`
