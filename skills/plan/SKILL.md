---
name: plan
description: Phase 3 of ClaudeHut workflow — break an approved contract into a file-level task list with 2–5 minute chunks, exact paths, RED test commands, GREEN implementation steps, DAG dependencies, and risk callouts. Use immediately after Spec phase approval. Produces `.claudehut/plans/<id>-plan.md`. Triggers when phase=plan.
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
