---
name: brainstorm
description: Use to generate and weigh solution approaches for a problem, after discovery has grounded the context. Produces two or more genuinely distinct options scored on trade-offs, recommends one, and (for code tasks) assembles the enforcement set the rest of the workflow audits against. General-purpose ideation — works for any problem type; not tied to a specific stack.
---

# Brainstorm (phase 2 of 7)

Turn a grounded problem into **≥2 genuinely distinct, well-reasoned approaches** and a recommendation. This is
**general-purpose ideation** — feature, bug, refactor, performance, design, or non-code decision. It does NOT
explore the codebase or run a reuse-scan: that is **Discover** (phase 1), whose context + reuse DECISION this
phase consumes. Decoupling ideation from discovery is deliberate (v0.4 reversal) — forcing explore+reuse here
narrowed the option space; freeing it widens creative breadth.

Run **inline on the main thread** (it owns the state write and the user gate; a forked subagent cannot spawn
subagents).

## Inputs (from Discover)

- The explorer's context map (entry points, key types, structure) and the **Reuse candidates**.
- The reuse-scan **DECISION** (adopt / extend / new) — option 0 is always "adopt/extend the existing thing"
  when Discover found a candidate.

## Steps

1. **Dispatch `claudehut:claudehut-brainstormer`** (Agent tool) with the problem statement + Discover's
   context. The agent runs its **fixed 6-step ideation pipeline** (FRAME criteria → DIVERGE ≥6 raw candidates
   incl. a wildcard, judgment deferred → CLUSTER to 2–4 structurally distinct → SCORE weighted matrix →
   PREMORTEM both finalists → RECOMMEND) and returns the options table with weighted scores + premortem risks
   + a recommendation. **Check the return against the pipeline**: ≥2 structurally distinct options, scores
   tied to explicit criteria, premortem present — send it back if any is missing. When Discover found a reuse
   candidate, adopting/extending it must appear as option 0.

   **Persist the deliberation** to `${CLAUDE_PROJECT_DIR}/.claude/claudehut/tasks/NNNN-<slug>/brainstorm.md`
   (the task dir from Discover's reuse-scan; the brainstormer has no Write — the main thread writes it): the
   options table + weighted scores + both premortems + the recommendation. The spec's §9 links it
   (`> brainstorm:` header). This is the fix for "the deliberation was generated then thrown away" — Spec
   stays terse (decision + why) while the *reasoning* is one click away, reviewable and auditable.
2. **Assemble the enforcement set (code tasks).** By the **1% rule** — *if there's even a 1% chance a skill or
   rule applies, include it* — scan the plugin skills and the project's `.claude/rules/` tree. The brainstormer
   returns the candidate set; the **main thread** records it:

   ```
   claudehut-state --session ${CLAUDE_SESSION_ID} set-enforcement --skills <a,b,c> --rules <framework/jpa.md,security/owasp-top10.md,…>
   ```
   The enforcement set is the auditable checklist Review enforces — and (v0.4) the **primary source for
   dynamic reviewer selection**: the rules it lists decide which specialist auditors Review spawns. A thin or
   empty set silently under-reviews — apply the 1% rule honestly.
3. **Confirm the choice (interactive only).** Call the **`AskUserQuestion` tool** with the scored options as
   choices (not a free-text ask) — records a structured decision before Spec. On a non-interactive run (`-p`)
   or inside a subagent (no `AskUserQuestion`), proceed with the brainstormer's recommendation.

## Red flags — STOP

- Only one option ("the obvious way") — the bar is ≥2 genuinely distinct approaches.
- Re-running explore/reuse here — that was Discover; if it didn't run, go back to `claudehut:discover`.
- Enforcement set left empty because "nothing really applies" — re-apply the 1% rule against `.claude/rules/`
  (it also determines which reviewers fire).

**REQUIRED NEXT:** `claudehut:write-spec`.
