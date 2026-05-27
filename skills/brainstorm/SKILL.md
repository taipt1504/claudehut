---
name: brainstorm
description: Phase 1 of ClaudeHut workflow — scan codebase + reuse-detection, draft a design document, run main-thread AskUserQuestion exchanges for any open decisions, converge on an approved design. Use when the user requests new functionality AND no task is active (phase=none), OR when explicitly invoked via /claudehut:brainstorm. Triggers on natural-language "add|implement|build|design|refactor|fix bug" with a noun (feature/endpoint/service/class/module/api).
---

## Dispatch contract (read this FIRST)

Brainstorm runs as a **scan-and-return subagent**, not as an interactive
dialog inside the subagent. The runtime split is non-negotiable:

| Actor | Owns |
|-------|------|
| Subagent `claudehut-brainstormer` (opus) | Codebase scan, reuse-scan, conventions read, **draft** design doc on disk, list of `open_questions[]`. **Terminates after one turn.** |
| Main thread (orchestrator) | User dialog via `AskUserQuestion`, plan tracking, looping back into the subagent with the user's answers. |

The reason for this split is documented in Anthropic's runtime contract:
`AskUserQuestion`, `Agent`, `EnterPlanMode`, `ScheduleWakeup`, and
`WaitForMcpServers` are **not available in any subagent context**
(source: code.claude.com/docs/en/sub-agents §Available tools). A
subagent that tries to "ask the user 5 questions" stalls because the
runtime silently strips the tool — the symptom is exactly what users
have reported.

### The loop

```
1. main thread runs:
     PROMPT=$( "$CLAUDE_PLUGIN_ROOT/skills/brainstorm/scripts/dispatch-prompt.sh" "$ARGUMENTS" )
     Task(subagent_type="claudehut-brainstormer", prompt="$PROMPT")

2. subagent scans + reuse-scans + drafts → saves .claudehut/specs/<id>-design.md
   subagent terminates with a fenced ```claudehut-brainstorm-return JSON block
   containing: findings, open_questions[], blockers, next_action.

3. main thread parses the return block:
     a. if next_action == "BLOCKED":
          surface the blocker, escalate to user, stop the loop.
     b. if next_action == "MAIN_ASKS_USER":
          render open_questions[] verbatim into a single AskUserQuestion call:
            AskUserQuestion(questions=[
              { question: q.question,
                options: q.options,
                multiSelect: q.multiSelect }
              for q in open_questions
            ])
          collect user answers, then re-dispatch:
            Task(claudehut-brainstormer, prompt=<dispatch-prompt with answers[]>)
          GOTO step 2.
     c. if next_action == "MAIN_REVIEWS_DRAFT":
          read .claudehut/specs/<id>-design.md
          summarise the draft to the user (≤ 8 lines), then ask
          AskUserQuestion(questions=[{
            question: "Approve this design and move to /claudehut:spec?",
            options: [
              { label: "Approve (Recommended)", value: "approve" },
              { label: "Revise — I'll specify in Other", value: "revise" }
            ],
            multiSelect: false
          }])
          if user picks "approve": commit phase advance to spec.
          if user picks "revise" (with notes in Other): re-dispatch with notes.

4. orchestrator advances phase=spec once the draft is approved + saved.
```

The dispatch script (`scripts/dispatch-prompt.sh`) deterministically
composes user intent + stack signals + conventions + recent learnings +
prior artifacts + the prior round's `answers[]` (if any).

**Do not execute the phase steps yourself in the main thread.** Spawn
the subagent every time. The main thread only relays user answers and
calls AskUserQuestion.

### Red flags

| Rationalization | Reality |
|-----------------|---------|
| "I'll just ask the user from inside the subagent." | `AskUserQuestion` is not available there. Subagent stalls. **Use the loop.** |
| "Subagent context is overkill for a small feature." | The subagent runs opus deliberately. Main thread may be on a different model. **Dispatch.** |
| "I already know the design." | Reuse-scan + conventions are not in main-thread context. **Dispatch.** |

**Only exception**: user explicitly types `--inline` or "don't spawn a
subagent". Then run the steps below inline and log the deviation in
`.claudehut/findings/`.

---

# Brainstorm — Phase 1

Turn vague user intent into an approved design document.

- **Subagent output (per turn)**: `claudehut-brainstorm-return` JSON
  block + saved/updated `.claudehut/specs/<id>-design.md`.
- **Main-thread output**: `AskUserQuestion` calls relaying the
  subagent's `open_questions[]` verbatim until convergence, then a
  final approve/revise question.

## Quick start (main thread)

1. Run the dispatch script → spawn brainstormer subagent.
2. Read the structured return block.
3. If `open_questions[]` non-empty → call AskUserQuestion with them
   (one call, multi-question). Re-dispatch with answers folded into
   the prompt.
4. Repeat 1-3 until `next_action == "MAIN_REVIEWS_DRAFT"`.
5. Show the saved draft to the user (≤ 8-line summary + path).
6. Final AskUserQuestion: approve / revise.
7. On approve: phase advances to `spec`.

## Workflow detail

For the full reuse-detection algorithm and backend matrix
(Understand-Anything, Graphify, grep fallback), load
`references/reuse-detection-flow.md`.

For the design doc self-review checklist (placeholder scan, ambiguity
detection, scope check), load `references/design-doc-checklist.md`.

For 3 worked examples (REST endpoint, Kafka consumer, Flyway
migration), load `references/examples.md`.

The earlier "Socratic grilling" reference is preserved at
`references/socratic-grilling.md` for the **subagent's own reasoning**
inside one turn (it chooses *which* open questions to surface based on
what is most blocking) — it is NOT a script for multi-turn dialog.

## Scripts

- `scripts/dispatch-prompt.sh "<user-args>"` — render the subagent
  task prompt; pipe the user's previous answers back in subsequent
  turns via the `ANSWERS_JSON` env var.
- `scripts/extract-nouns.sh <prompt>` — extract candidate noun list
  from user prompt for reuse-scan input (used by the subagent).
- `scripts/design-doc-selfreview.sh <path>` — scan a design doc for
  placeholders and ambiguity, exit non-zero on issue.

## Assets

- `assets/templates/design-doc.md.tmpl` — design document skeleton
  with all required sections. The subagent writes `<TBD:question-id>`
  placeholders for any section blocked on an open question.

## Hard rules

- The subagent never asks the user a question in prose; every question
  is data in `open_questions[]`.
- The main thread never inlines the scan; every loop iteration spawns
  the subagent.
- MUST run reuse-scan before drafting (the subagent's G1).
- MUST save the draft before terminating (the subagent's G2).
- Self-review must be clean except for placeholders that match active
  open question ids (the subagent's G3).
- User approval is captured via AskUserQuestion's structured response,
  not a free-text "looks good".

## Exit criteria

- [ ] `.claudehut/specs/<id>-design.md` exists, no `<TBD:*>` placeholders remaining.
- [ ] `scripts/design-doc-selfreview.sh` exits 0.
- [ ] Final AskUserQuestion returned `approve`.
- [ ] Phase auto-advances to `spec`.
