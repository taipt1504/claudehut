---
name: build
description: Phase 4 of ClaudeHut — execute the approved plan by dispatching each parallel group as concurrent native builder subagents (Task, each in its own git worktree), then merging. Groups run in order; tasks within a group run simultaneously. Strict TDD per task. Triggers when phase=build.
---

## Dispatch contract (read this FIRST)

This phase executes each parallel group as **native `Task(subagent_type="claudehut:claudehut-builder")` subagents — one per task, all dispatched in a SINGLE message** so they run concurrently AND appear in the agent tracker (you can see + control each builder's status, exactly like every other phase). `scripts/prep-parallel-group.sh` does the setup — one isolated **git worktree** + one ready-to-dispatch prompt per task — and prints a JSON manifest; you dispatch the Tasks from it; `scripts/merge-parallel-group.sh` cherry-picks the passing branches.

Trade-off (since v0.1.x, chosen for observability): native Task workers run **in-session**, so there is **NO per-worker pre-launch budget cap**. Bound runaway builders with attention + the now-visible tracker. The legacy headless pool **`scripts/run-parallel-group.sh`** — which forks `claude --print` workers WITH the per-worker budget gate but is NOT tracker-visible — remains as a fallback for budget-critical / headless runs (see Scripts, end of file).

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

# ── Group loop (native Task) ──────────────────────────────────────────
for G in GROUPS:
  1. Run: scripts/prep-parallel-group.sh "$ARGUMENTS" TASK_ID PLAN G
     → creates one git worktree + one prompt per unchecked task; prints a JSON
       manifest (also at .claudehut/logs/groupG-manifest.json). Empty tasks → skip group.
  2. For EACH manifest entry, dispatch ONE:
       Task(subagent_type="claudehut:claudehut-builder", prompt = contents of entry.prompt_file)
     ALL IN A SINGLE MESSAGE so the builders run concurrently and show in the tracker.
     NEVER give one builder more than one task.
  3. Collect each builder's claudehut-builder-result block. Gather "task_num:branch"
     for every entry whose verify_status == pass.
  4. Merge: scripts/merge-parallel-group.sh TASK_ID PLAN <num:branch> [<num:branch> …]
     (cherry-picks the passing worktree branches onto the main checkout + ticks checkboxes).
  5. Cleanup: scripts/prep-parallel-group.sh --cleanup .claudehut/logs/groupG-manifest.json
  6. Per-group gate (main checkout): ./gradlew compileTestJava test
     Any worker fail OR gate fail → surface to user; await decision before the next group.

After last group:
  ./gradlew check  (or mvn verify)
  Advance phase to loop
```

`scaffold-stubs.sh` runs once: generates + commits compiling stubs from `contract.md` + plan.
`prep-parallel-group.sh` per group: creates **worktrees** + per-task prompts + a manifest (NO model calls); you dispatch native Task builders from it; `merge-parallel-group.sh` merges the passing branches.

---

# Build — Phase 4

Execute the plan with strict TDD discipline. The ONLY phase where production code is written.

## Quick start (native Task builders — visible in the agent tracker)

1. Read `.claudehut/plans/<id>-plan.md`. Extract all distinct `Parallel group:` values.
2. Run `scripts/scaffold-stubs.sh "$ARGUMENTS" <task-id>` once. Non-zero exit → stop, surface.
3. For each group G in order:
   a. `scripts/prep-parallel-group.sh "$ARGUMENTS" <task-id> <plan-file> G` → worktrees + prompts + manifest.
   b. Dispatch one `Task(subagent_type="claudehut:claudehut-builder", prompt=<prompt_file>)` per manifest entry, **all in one message** (concurrent + tracked). One task per builder.
   c. Collect `claudehut-builder-result` blocks → pass `<num:branch>` of passing tasks to `scripts/merge-parallel-group.sh <task-id> <plan-file> …`.
   d. `scripts/prep-parallel-group.sh --cleanup .claudehut/logs/groupG-manifest.json`; then `./gradlew compileTestJava test`. Fail → surface; await decision.
4. After last group: `./gradlew check`; advance phase to `loop`.

Each builder works in its assigned worktree via **ABSOLUTE PATHS** (its shell cwd does NOT persist across Bash calls; use `git -C "<worktree>"`): RED → GREEN → REFACTOR → commit → emit result, branching from the stub commit.

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
- `scripts/prep-parallel-group.sh "<user-intent>" <task-id> <plan-file> <group-num>` — **native-Task setup (primary)**: create one git worktree + one self-contained prompt per unchecked task and print a JSON manifest the orchestrator dispatches `Task(claudehut:claudehut-builder)` from. `--cleanup <manifest>` removes the worktrees after merge. NO model calls.
- `scripts/dispatch-prompt.sh "<user-intent>" <task-num>` — single-task builder prompt (embedded by prep into each manifest prompt; task-num selects the plan task block).
- `scripts/merge-parallel-group.sh <task-id> <plan-file> [task-num:branch ...]` — cherry-pick each passing worktree branch onto main and tick plan checkboxes.
- `scripts/run-parallel-group.sh "<user-intent>" <task-id> <plan-file> <group-num>` — **legacy fallback**: forks headless `claude --print` workers in worktrees (OS-level parallelism + the Phase-5 per-worker budget gate) instead of native Task; NOT tracker-visible. Use for budget-critical / headless runs. Tunables: `CLAUDEHUT_WORKER_MODEL` (default sonnet), `CLAUDEHUT_TASK_TIMEOUT` (default 900s). **Exit 3 → BUDGET HALT**: reads `.claudehut/state/budget-breach.json` (spend_usd / cap_usd / tasks_unstarted); do NOT retry — raise `budget.max_worker_pool_usd` or route quick.
- Surgical-scope enforcement is inline in the wired PreToolUse hook (`hooks/pre-tool.sh`); it denies Write/Edit of files not in the current task's plan.

## Exit criteria

- [ ] Every task in plan checked ✓
- [ ] `./gradlew check` (or Maven `verify`) passes locally
- [ ] No surgical-scope violations recorded
- [ ] Phase advanced to `loop`
