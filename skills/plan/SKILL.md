---
name: plan
description: Phase 3 of ClaudeHut — break an approved contract into a file-level task list: 2-5 min chunks, exact paths, RED test commands, GREEN steps, DAG dependencies, risk callouts. Produces .claudehut/plans/<id>-plan.md. Triggers when phase=plan.
---

## Dispatch contract (read this FIRST)

This phase runs as a **subagent**, not inline in the main thread.
Main thread = orchestrator (context, memory, advisor, task tracking, user
dialog). Phase work = subagent (isolated context, per-phase model).

When you read this skill, you **MUST** invoke the Task tool:

```
Task(
  subagent_type = "claudehut:claudehut-planner",
  prompt        = <output of scripts/dispatch-prompt.sh "$ARGUMENTS">
)
```

Render the prompt by running `$CLAUDE_PLUGIN_ROOT/skills/plan/scripts/dispatch-prompt.sh "$ARGUMENTS"` and pass the stdout verbatim as the Task `prompt` argument. The script composes user intent + stack signals + conventions + recent learnings + prior-phase artifacts deterministically.

Do **not** execute the phase steps yourself in the main thread.
Await the subagent's return, review the artifact it wrote, surface a
concise status back to the user.

**Red flags that say "skip dispatch"** (counter each, do not give in):

| Rationalization | Reality |
|---|---|
| "This task is small — I'll inline it." | Inline = no isolated context + wrong model + breaks workflow gate. **Dispatch.** |
| "Subagent context is overkill." | This phase intentionally runs on `opus`. Main thread may be a different model — wrong tool. **Dispatch.** |
| "Tasks are obvious — no plan needed." | Build phase reads plan; PreToolUse blocks files not in plan. **Dispatch.** |
| "I'll plan as I go." | TDD requires file-level tasks upfront. **Dispatch.** |

**Only exception**: user explicitly types `--inline` or "don't spawn a subagent". Then proceed inline and log the deviation in `.claudehut/findings/`.

---

# Plan — Phase 3

Make a plan so concrete a junior engineer could execute it without rereading the spec.

## Quick start

1. Read approved contract: `.claudehut/specs/<id>-contract.md`.
2. Render `assets/templates/plan-doc.md.tmpl`.
3. For each AC in the contract, derive 1+ tasks. Each task: 2–5 min, single test method.
4. List exact file paths, RED command, GREEN summary, verify command, risk tag.
5. Run `scripts/plan-placeholder-scan.sh` AND `scripts/plan-spec-coverage.sh`.
6. Save plan, await user `approve`.

## Task atomization rules

- Each task = ONE failing test → ONE minimal implementation → commit.
- Maximum 5 minutes wall-clock per task.
- ZERO placeholders ("TBD", "similar to task N", "add validation", "etc.")
- File paths absolute from project root; create-tasks marked `create:`.
- Risk tag any task touching: DB migration, public API, security boundary, > 1 module.

Detailed atomization heuristics: `references/task-atomization.md`. DAG construction: `references/dag-dependency.md`. Risk taxonomy: `references/risk-callout-taxonomy.md`. Worked examples: `references/examples.md`.

## Scripts

- `scripts/plan-placeholder-scan.sh <path>` — reject "TBD" / vague language.
- `scripts/plan-spec-coverage.sh <plan> <contract>` — verify every AC maps to ≥ 1 task.

## Assets

- `assets/templates/plan-doc.md.tmpl` — plan skeleton.

## Hard rules

- Every task must be runnable as a single test command
- File paths must be checkable (find/test -f) before plan approval
- Verify command MUST exit 0 to mark task done
- Risk tasks MUST have a mitigation note

## Exit criteria

- [ ] Plan file saved
- [ ] Both validation scripts exit 0
- [ ] Spec coverage: every AC maps to ≥ 1 task
- [ ] User typed `approve`
- [ ] Phase advanced to `build`
