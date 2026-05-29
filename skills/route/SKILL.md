---
name: route
description: Phase 0.5 of ClaudeHut workflow — triage the task's intent and choose the pipeline DEPTH (the Routing pattern). Classifies the request into a profile (quick = build+verify only, or full = the 6-phase pipeline) and records it as `.claudehut/state/route-<id>.json`. Use as the FIRST step of any new task, before Brainstorm. Triggers when phase=route.
---

## Dispatch contract (read this FIRST)

Routing runs **inline on the main thread** — it is a single deterministic
classification plus one file write. Do **NOT** dispatch a subagent for it:
spinning up an isolated context to label a one-line request is exactly the
overhead adaptive-depth exists to remove. (Routing pattern, Anthropic
"Building Effective Agents": *"Routing works well … where classification can be
handled accurately, either by an LLM or a more traditional classification
model/algorithm."* Here it is a cheap deterministic algorithm with you, the
orchestrator, as the override.)

## Why this phase exists

Anthropic's guidance: *"find the simplest solution possible, and only increasing
complexity when needed … add multi-step agentic systems only when simpler
solutions fall short."* The 6-phase pipeline IS the multi-step system. Forcing
it on a one-line fix burns ~9× the cost and (under a budget cap) can fail to
even reach the fix — measured, see `evals/results/`. This phase matches pipeline
depth to the task so trivial work stays cheap and real features keep the full
gate.

## Steps

1. **Classify.** Feed the user's task description to the deterministic classifier:

   ```bash
   "$CLAUDE_PLUGIN_ROOT/skills/route/scripts/classify.sh" "<the user's task description>"
   ```

   It prints `{profile, db_review, reason, signal}`. The classifier is
   conservative: it only suggests `quick` on an explicit trivial signal with no
   complexity/migration signal — otherwise `full`.

2. **Decide (you may override).** Accept the suggestion unless you have a
   *statable* reason to override. The bar for `quick` is high — when unsure,
   choose `full`. Verify (the quality gate) runs in BOTH profiles, so the only
   thing `quick` risks is skipped up-front design on a task that turns out
   non-trivial; that surfaces at Verify, not in production.

   | Profile | Phases | Choose when |
   |---------|--------|-------------|
   | `quick` | build → loop | One-line / few-line fix, no new types, no schema change, no new integration. (typo, wrong operator, null check, rename, comment) |
   | `full`  | brainstorm → spec → plan → build → loop → learn | Anything else: new feature/endpoint/service, refactor across files, migration, messaging, design decisions. **Default.** |

3. **Record it.** Persist the decision (this advances the phase automatically):

   ```bash
   "$CLAUDE_PLUGIN_ROOT/skills/route/scripts/write-route.sh" <quick|full> [--db-review] --reason "<one line>"
   ```

   Pass `--db-review` for any migration/DDL/schema task (the classifier sets
   `db_review` for you — mirror it). It is advisory metadata; the DB reviewer is
   already dispatched automatically whenever the diff touches `db/migration/`,
   `*Repository.java`, or `*Entity.java`, so a migration gets DB review either way.

## After routing

`route-<id>.json` now exists → `claudehut_phase` derives from the profile:

- **quick** → next phase is `build`. Make the fix, commit, then go straight to
  `/claudehut:verify-review`. There is **no plan** in quick mode — surgical-scope
  and reuse-scan gates self-disable (no plan to check; you edit existing files).
- **full** → next phase is `brainstorm`. Proceed exactly as the standard pipeline.

Re-read the phase after writing the route; do not assume.

## Guardrails

- Routing is a **recorded** decision, not an ad-hoc skip. Never tell the user
  "let's skip the workflow for this small fix" — instead route to `quick`, which
  records *why* depth was reduced and still runs the Verify gate.
- Never choose `quick` to save time on a task you suspect is non-trivial. The
  cost of an unnecessary `full` is tokens; the cost of a wrong `quick` is an
  unreviewed design. Asymmetric — default `full`.
- One route per task. To change depth mid-task, rewrite the route artifact
  deliberately (e.g. Verify revealed the "trivial" fix needs a real design →
  re-route to `full`).
