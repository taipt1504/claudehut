---
name: claudehut-workflow
description: Use at the start of every session and whenever beginning a coding task in a Java/Spring backend - establishes the ClaudeHut 6-phase agentic workflow and the laws that govern which skills and rules must fire. Injected at session start; also re-anchor mid-session with /claudehut:workflow.
---

# ClaudeHut Workflow

You are operating under ClaudeHut. The codebase is **pre-indexed** (see `claudehut:claudehut-init`). Every coding task moves through **6 phases** — you are always in exactly one:

```
Brainstorm → Spec → Plan → Implement → Review → Learn
```

## The laws (non-negotiable)

1. **Skill-first.** Before responding or acting, check whether a ClaudeHut skill applies.
2. **1% rule.** *If you think there is even a 1% chance a skill or rule might apply to what you are doing, you ABSOLUTELY MUST invoke it.* This is how the **enforcement set** is built in Brainstorm. This is not negotiable. You cannot rationalize your way out of it.
3. **Reuse-first.** Never write new code before the reuse-scan step in `claudehut:brainstorm` (hook-gated).
4. **Test-first.** Never write production code before a failing test — `claudehut:implement` (Iron Law).
5. **Compliance-first.** Never claim a task is done before `claudehut:review` reports zero outstanding items (hook-gated).
6. **Canonical store — one dir per task.** Every artifact of a task — reuse-scan, spec, plan, review — lives in that task's dir `${CLAUDE_PROJECT_DIR}/.claude/claudehut/tasks/NNNN-<slug>/` (created in Brainstorm; `NNNN` = next integer over `tasks/`; never a bare `specs/`/`plans/` or a `.claudehut/` path). The write gate verifies files exist under `.claude/claudehut/`; off-path artifacts are invisible to the gate, to `@import` memory, and to the next session. Global stores stay at the root: `learnings.jsonl`, `reuse-index.json`, the memory plane, `state/`.
7. **Main thread orchestrates.** Skills run on the main thread and own the user gates (`AskUserQuestion`), the state writes (`claudehut-state`), and the native task mirror (`TaskCreate`/`TaskUpdate`). Subagents do isolated work and **return data** — they never write state and never ask the user (they can't: no `AskUserQuestion`, and most have no Bash).

**Violating the letter of these laws is violating the spirit of them.**

## Phase → skill map

| Phase | Invoke | Heavy work (Agent tool) | User gate (interactive) | Produces (in `tasks/NNNN-<slug>/`) |
|-------|--------|------------------------|-------------------------|-------------------------------------|
| 1. Brainstorm | `claudehut:brainstorm` | explorer → reuse-scanner → brainstormer | choose approach | `reuse-scan.md` + enforcement set |
| 2. Spec | `claudehut:write-spec` | — (main thread writes from template) | **approve spec** → then `set-spec` | `spec.md` |
| 3. Plan | `claudehut:write-plan` | planner drafts from template | **approve plan** → then `set-plan` + native task mirror | `plan.md` (T-xxx breakdown) |
| 4. Implement | `claudehut:implement` | implementer if >2 files or a migration; `[P]` tasks → parallel implementers in ONE message (gated by `claudehut-worktree check-disjoint`); inline otherwise | — | code + tests (test-first; path-scoped `.claude/rules/` auto-load) |
| 5. Review | `claudehut:review` | 5 auditors in parallel | — | `review.md`; loops until outstanding is empty |
| 6. Learn | `claudehut:capture-learnings` | learner | — | `learnings.jsonl` records + updated index |

Announce each phase: state *"Using ClaudeHut <skill> (phase N)"* when you invoke it.

## Recording transitions

State is per-session, recorded **by the main thread only** with the state writer (it is the only writer;
hooks read it; subagents never call it):

```
claudehut-state --session ${CLAUDE_SESSION_ID} set-phase <name> [--spec <path> | --plan <path> | ...]
```

The hard gates depend on this: the write gate blocks new code until reuse-scan + spec + plan exist; the completion gate blocks "done" until review passes and Learn has run.

**REQUIRED NEXT:** begin at phase 1 — invoke `claudehut:brainstorm`. Do NOT jump to Implement.
