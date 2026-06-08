---
name: claudehut-workflow
description: Use at the start of every session and whenever beginning a coding task in a Java/Spring backend - establishes the ClaudeHut 7-phase agentic workflow, the complexity-tier routing that lets small tasks skip deliberation phases, and the laws that govern which skills and rules must fire. Injected at session start; also re-anchor mid-session with /claudehut:workflow.
---

# ClaudeHut Workflow

You are operating under ClaudeHut. The codebase is **pre-indexed** (see `claudehut:claudehut-init`). The full
workflow is **7 phases** — you are always in exactly one:

```
Discover → Brainstorm → Spec → Plan → Implement → Review → Learn
```

## Phase 0 — Triage the request (do this first, every task)

Not every task needs all seven phases. Assess complexity, pick a tier, record it
(`claudehut-state --session ${CLAUDE_SESSION_ID} set-complexity <tier>`), then run only that tier's phases.
**You propose the tier; the write gate verifies its bound deterministically — you cannot route a large or
security-touching change into a fast lane.**

| Tier | When (your assessment) | Phases run | Skips |
|------|------------------------|------------|-------|
| **trivial** | comment/doc/rename/config-value; no logic change | Discover (quick) → Implement → Review (min) | Brainstorm, Spec, Plan |
| **small** | ≤2 files, no new component, **no security/auth/migration surface** | Discover → Implement → Review (dynamic) → Learn | Brainstorm, Spec, Plan |
| **full** (default) | new component, multi-file, architectural, OR any security/auth/migration surface | all 7 | — |

**Safety rails are never skipped in any tier:** the reuse-scan (Discover), test-first (Implement Iron Law),
and a Review pass. Only the *deliberation* phases (Brainstorm/Spec/Plan) are skipped. If unsure, default to
**full** — or in interactive use confirm the tier with `AskUserQuestion`. If a fast-lane write is denied
because it grew past the bound (>2 files or a sensitive path), the gate tells you to escalate:
`set-complexity full` and run Spec + Plan.

## The laws (non-negotiable)

1. **Skill-first.** Before responding or acting, check whether a ClaudeHut skill applies.
2. **1% rule.** *If you think there is even a 1% chance a skill or rule might apply to what you are doing, you ABSOLUTELY MUST invoke it.* This is how the **enforcement set** is built in Brainstorm (and it drives which reviewers Review spawns). This is not negotiable. You cannot rationalize your way out of it.
3. **Reuse-first.** Never write new code before the reuse-scan step in `claudehut:discover` (hook-gated; required in every tier).
4. **Test-first.** Never write production code before a failing test — `claudehut:implement` (Iron Law).
5. **Compliance-first.** Never claim a task is done before `claudehut:review` reports zero outstanding items (hook-gated).
6. **Canonical store — one dir per task.** Every artifact of a task — reuse-scan, spec, plan, review — lives in that task's dir `${CLAUDE_PROJECT_DIR}/.claude/claudehut/tasks/NNNN-<slug>/` (created in Brainstorm; `NNNN` = next integer over `tasks/`; never a bare `specs/`/`plans/` or a `.claudehut/` path). The write gate verifies files exist under `.claude/claudehut/`; off-path artifacts are invisible to the gate, to `@import` memory, and to the next session. Global stores stay at the root: `learnings.jsonl`, `reuse-index.json`, the memory plane, `state/`.
7. **Main thread orchestrates.** Skills run on the main thread and own the user gates (`AskUserQuestion`), the state writes (`claudehut-state`), and the native task mirror (`TaskCreate`/`TaskUpdate`). Subagents do isolated work and **return data** — they never write state and never ask the user (they can't: no `AskUserQuestion`, and most have no Bash).

**Violating the letter of these laws is violating the spirit of them.**

## Phase → skill map

| Phase | Invoke | Heavy work (Agent tool) | Tiers | Produces (in `tasks/NNNN-<slug>/`) |
|-------|--------|------------------------|-------|-------------------------------------|
| 1. Discover | `claudehut:discover` | explorer ∥ reuse-scanner (one message) | all | `reuse-scan.md` + reuse DECISION |
| 2. Brainstorm | `claudehut:brainstorm` | brainstormer (generic ideation) | full | ≥2 options + enforcement set |
| 3. Spec | `claudehut:write-spec` | — (main writes from template); **approve spec** → `set-spec` | full | `spec.md` |
| 4. Plan | `claudehut:write-plan` | planner drafts from template; **approve plan** → `set-plan` + task mirror | full | `plan.md` (T-xxx breakdown) |
| 5. Implement | `claudehut:implement` | main thread walks the plan **phase by phase**; within each phase the `[P]`/independent tasks → parallel implementers in ONE message (`check-disjoint`, max 3), dependent tasks → one implementer each, inline if ≤2 files; native task list updated at each phase boundary | all | code + tests (test-first; `.claude/rules/` auto-load) |
| 6. Review | `claudehut:review` | **dynamically selected** auditors in parallel (test-runner + reviewer always; specialists by impact) | all | `review.md`; loops until outstanding empty |
| 7. Learn | `claudehut:capture-learnings` | learner | full + small | `learnings.jsonl` records + updated index |

Announce each phase: state *"Using ClaudeHut <skill> (phase N)"* when you invoke it.

**Parallel dispatch convention.** When a phase dispatches multiple subagents with no data dependency between
them (Discover's explorer + reuse-scanner; Review's selected auditors; Implement's disjoint `[P]` group
within a phase after `check-disjoint` passes), issue all those Agent tool calls **in one message** — independent calls in the same
message run concurrently; one call per message runs them serially. Dependent dispatches stay sequential.
Dispatch plugin agents by their qualified type (`claudehut:claudehut-<name>`).

## Recording transitions

State is per-session, recorded **by the main thread only** with the state writer (it is the only writer;
hooks read it; subagents never call it):

```
claudehut-state --session ${CLAUDE_SESSION_ID} set-phase <name> [--spec <path> | --plan <path> | ...]
```

The hard gates depend on this: the write gate blocks new code until the reuse-scan exists (every tier) plus
spec + plan (full tier); the completion gate blocks "done" until review passes and Learn has run.

**REQUIRED NEXT:** triage the request (Phase 0), then begin at phase 1 — invoke `claudehut:discover`. Do NOT
jump to Implement.
