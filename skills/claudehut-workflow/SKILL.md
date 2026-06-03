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
6. **Canonical store.** Every workflow artifact — reuse-scan, spec, plan, learnings — MUST be written under `${CLAUDE_PROJECT_DIR}/.claude/claudehut/` (never a bare `specs/`/`plans/` or a `.claudehut/` path). The write gate verifies the file exists there; off-path artifacts are invisible to the gate, to `@import` memory, and to the next session.

**Violating the letter of these laws is violating the spirit of them.**

## Phase → skill map

| Phase | Invoke | Produces |
|-------|--------|----------|
| 1. Brainstorm | `claudehut:brainstorm` (explore → reuse-scan → options, inline) | ≥2 codebase-adapted options + reuse-scan artifact + enforcement set |
| 2. Spec | `claudehut:write-spec` | implementation spec (`specs/<task>.md`) |
| 3. Plan | `claudehut:write-plan` | executable plan (`plans/<task>.md`) |
| 4. Implement | `claudehut:implement` (test-first; path-scoped `.claude/rules/` auto-load) | code + tests (test-first) |
| 5. Review | `claudehut:review` | auditor findings; loops until outstanding is empty |
| 6. Learn | `claudehut:capture-learnings` | new `learnings.jsonl` records + updated index |

Announce each phase: state *"Using ClaudeHut <skill> (phase N)"* when you invoke it.

## Recording transitions

State is per-session. Record every transition with the state writer (it is the only writer; hooks read it):

```
claudehut-state --session ${CLAUDE_SESSION_ID} set-phase <name> [--spec <path> | --plan <path> | ...]
```

The hard gates depend on this: the write gate blocks new code until reuse-scan + spec + plan exist; the completion gate blocks "done" until review passes and Learn has run.

**REQUIRED NEXT:** begin at phase 1 — invoke `claudehut:brainstorm`. Do NOT jump to Implement.
