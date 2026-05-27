---
name: brainstorm
description: Phase 1 of ClaudeHut workflow — Socratic grilling, reuse-detection scan, design document drafting for a Java backend feature/refactor/bugfix. Use when the user requests new functionality AND no task is active (phase=none), OR when explicitly invoked via /claudehut:brainstorm. Triggers natural-language match on "add|implement|build|design|refactor|fix bug" with a noun (feature/endpoint/service/class/module/api).
---

# Brainstorm — Phase 1

Turn vague user intent into an approved design document. Output: `.claudehut/specs/<id>-design.md`. Do NOT write production code in this phase.

## Quick start

1. Read `.claudehut/memory/conventions.md` and `stack-signals.json` to ground context.
2. Run `/claudehut:reuse-scan $ARGUMENTS` — present candidates if any.
3. Ask ONE clarifying question per turn (max 5 rounds).
4. Propose 2–3 approaches with trade-offs.
5. Draft design doc → save to `.claudehut/specs/YYYY-MM-DD-<slug>-design.md`.
6. Self-review (`scripts/design-doc-selfreview.sh`).
7. Await user `approve`.

## Workflow detail

For the full Socratic question sequence, anti-patterns, and stopping criteria, load `references/socratic-grilling.md`.

For the reuse-detection algorithm and backend matrix (Understand-Anything, Graphify, grep fallback), load `references/reuse-detection-flow.md`.

For the design doc self-review checklist (placeholder scan, ambiguity detection, scope check), load `references/design-doc-checklist.md`.

For 3 worked examples (REST endpoint, Kafka consumer, Flyway migration), load `references/examples.md`.

## Scripts

- `scripts/extract-nouns.sh <prompt>` — extract candidate noun list from user prompt for reuse-scan input.
- `scripts/design-doc-selfreview.sh <path>` — scan a design doc for placeholders and ambiguity, exit non-zero if issues.

## Assets

- `assets/templates/design-doc.md.tmpl` — design document skeleton with all required sections.

## Hard rules

- ONE clarifying question per turn. Do not batch.
- MUST run reuse-scan before proposing new implementations.
- MUST save design doc to disk before requesting approval.
- After 5 grilling rounds without convergence → propose with stated uncertainty.

## Exit criteria

- [ ] `.claudehut/specs/<id>-design.md` exists with all required sections
- [ ] Self-review script exits 0
- [ ] User typed `approve` (recorded in `state/tasks/<id>/phase.json#approvals.brainstorm`)
- [ ] Phase advanced to `spec`
