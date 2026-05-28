---
name: build
description: Phase 4 of ClaudeHut workflow — execute the approved plan by dispatching each parallel group of tasks as concurrent builder subagents (each in its own git worktree), then merging results. Tasks within the same Parallel group run simultaneously; groups run in order. Strict TDD enforced per task. Use after Plan phase approval. Triggers when phase=build.
---

## Dispatch contract (read this FIRST)

This phase dispatches **one isolated `claudehut-builder` subagent per plan task**, grouped by `Parallel group:` so independent tasks execute concurrently.

Main thread = orchestrator (parallel dispatch, worktree merge-back, checkbox ticking, user dialog).
Each builder = isolated subagent in its own git worktree (no git conflicts, no gradle contention).

### Parallel-group execution loop

```
PLAN = .claudehut/plans/<task-id>-plan.md
GROUPS = sorted distinct "Parallel group:" values from PLAN (1, 2, 3 …)

for G in GROUPS:
  TASKS = all unchecked tasks in PLAN where Parallel group == G

  # ── Dispatch all tasks in this group in ONE message ──────────────────
  # Single turn = concurrent execution. NEVER loop and dispatch one-by-one.
  for each T in TASKS:
    PROMPT = run $CLAUDE_PLUGIN_ROOT/skills/build/scripts/dispatch-prompt.sh \
                  "$ARGUMENTS" "$T.number"
    Agent(
      subagent_type = "claudehut-builder",
      isolation     = "worktree",
      prompt        = PROMPT
    )

  # ── Wait for all — collect claudehut-builder-result blocks ────────────
  RESULTS = all returned results for group G

  # ── Merge successful worktrees back to main branch ────────────────────
  PASS_PAIRS = ["N:branch" for R in RESULTS where R.verify_status == "pass"]
  run $CLAUDE_PLUGIN_ROOT/skills/build/scripts/merge-parallel-group.sh \
        "<task-id>" PLAN PASS_PAIRS...

  # ── Surface failures before continuing ────────────────────────────────
  FAILURES = [R for R in RESULTS where R.verify_status == "fail"]
  if FAILURES:
    surface errors to user; await decision before next group

# ── Final full-suite check ────────────────────────────────────────────
./gradlew check  (or mvn verify)
phase advances to loop
```

**All agents for a parallel group MUST be dispatched in a single message.** Dispatching them in separate turns serializes execution — defeats the entire purpose.

**Red flags that say "skip parallel dispatch"** (counter each, do not give in):

| Rationalization | Reality |
|---|---|
| "This task is small — I'll inline it." | Inline = no isolated context + wrong model + breaks workflow gate. **Dispatch.** |
| "Tasks are independent — I'll serialize to be safe." | Independent = same `Parallel group` = dispatch all at once. Serializing is exactly the 30-min problem being fixed. **Dispatch all in one message.** |
| "Worktree isolation is overkill for one task." | Worktree prevents git index lock + gradle contention. Always use `isolation: worktree`. |
| "Quick fix — no need for TDD cycle." | TDD is non-negotiable per workflow contract. **Dispatch.** |

**Only exception**: user explicitly types `--inline` or "don't spawn a subagent". Then proceed inline and log the deviation in `.claudehut/findings/`.

---

# Build — Phase 4

Execute the plan with strict TDD discipline. The ONLY phase where production code is written.

## Quick start

1. Read `.claudehut/plans/<id>-plan.md`. Extract all distinct `Parallel group:` values.
2. For group 1: dispatch all group-1 tasks as parallel `Agent(isolation: worktree)` calls — one message, multiple calls.
3. Wait for results. Run `scripts/merge-parallel-group.sh` for successful tasks.
4. Surface failures to user; on resolution proceed to group 2.
5. Repeat for each group in order.
6. After last group: `./gradlew check`; advance phase to `loop`.

Each builder subagent handles its task autonomously (RED → GREEN → REFACTOR → commit → emit result).

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

- `scripts/dispatch-prompt.sh "<user-intent>" <task-num>` — generate a single-task builder prompt (task-num selects which plan task block to include).
- `scripts/merge-parallel-group.sh <task-id> <plan-file> [task-num:branch ...]` — cherry-pick each worktree branch onto main and tick plan checkboxes.
- `scripts/pre-write-scope-check.sh <file>` — verify file is in current task's allowed scope (called by PreToolUse).

## Exit criteria

- [ ] Every task in plan checked ✓
- [ ] `./gradlew check` (or Maven `verify`) passes locally
- [ ] No surgical-scope violations recorded
- [ ] Phase advanced to `loop`
