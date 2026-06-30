---
name: write-spec
description: Use in the Spec phase after an approach is chosen in Brainstorm and before planning - produces the implementation spec from the standard template (EARS requirements, acceptance criteria, MADR decision record, enforcement manifest) and gets the user's approval before recording it. Runs inline on the main thread (it owns the approval gate and the state write).
allowed-tools: Read Grep Glob Write Bash AskUserQuestion
---

# Write Spec (Spec phase)

Turn the chosen approach into the **contract** the implementation and Review are graded on. Runs **inline on the main thread** — this skill owns a user gate (`AskUserQuestion`) and a state write (`claudehut-state`), which subagents cannot do.

## Flow

```mermaid
flowchart TB
  start(["approach chosen in Brainstorm"]) --> dir{"reuse-scan recorded<br/>in session state?"}
  dir -- "no" --> back(["BLOCKED: go back to Brainstorm<br/>(it owns task-dir creation)"])
  dir -- "yes" --> derive["derive task dir = dirname(reuse-scan)<br/>NEVER recompute next NNNN"]
  derive --> size{"type == feature?"}
  size -- "yes" --> full["write spec.md — ALL ## sections<br/>(template, canonical .claude/claudehut path)"]
  size -- "no" --> red["write spec.md — reduced subset<br/>(1,9,5,10,12) — no N/A walls"]
  full --> crit["REFUTE before recording — assume it fails set-spec:<br/>has ## sections + Decision Record + AC-xxx?<br/>every chosen-option commitment traces to an AC?"]
  red --> crit
  crit --> gate{"set-spec preconditions met<br/>AND every commitment maps to ≥1 AC?"}
  gate -- "no" --> fix["fix structure / add missing AC"]
  fix --> crit
  gate -- "yes" --> mode{"interactive run<br/>(AskUserQuestion available)?"}
  mode -- "no" --> nonint["record 'approval: non-interactive<br/>run — proceeded with draft' in header"]
  nonint --> record
  mode -- "yes" --> ask["AskUserQuestion — summarize 3-5 lines<br/>(decision, key ACs, scope): Approve / Request changes"]
  ask --> verdict{"Approved?"}
  verdict -- "no — revise and re-ask" --> fix
  verdict -- "yes" --> record["set-spec .claude/claudehut/tasks/NNNN-slug/spec.md<br/>(arms write gate's spec requirement)"]
  record --> done(["REQUIRED NEXT: claudehut:write-plan"])
```

## Process

Derive the task dir from the recorded reuse-scan (`dirname` of `set-reuse-scan --artifact`) — never recompute "next NNNN". Write the spec from `references/spec-template.md` to the canonical path `${CLAUDE_PROJECT_DIR}/.claude/claudehut/tasks/NNNN-<slug>/spec.md` (never a bare `specs/` or `.claudehut/` path). Right-size by type: `feature` → all sections; `refactor`/`bugfix` → the reduced subset, no "N/A" walls. Use these exact `##` headings (full guidance in the reference):
`1. Problem & Context · 2. Goals / Non-Goals · 3. User Story · 4. Functional Requirements (EARS FR-xxx) ·
5. Acceptance Criteria (GWT AC-xxx) · 6. API Contract Changes · 7. Data Model Changes · 8. NFRs ·
9. Decision Record · 10. Out of Scope · 11. Open Questions · 12. Enforcement Manifest`
(reduced subset = 1, 9, 5, 10, 12). **`claudehut-state set-spec` REJECTS a file with no `## ` sections or no Decision Record** — a freeform spec will not arm the gate. **Only after approval** record it (do NOT run it before the user approves):

```
claudehut-state --session ${CLAUDE_SESSION_ID} set-spec .claude/claudehut/tasks/NNNN-<slug>/spec.md
```

Do NOT write production code yet — the write gate stays closed until a plan exists. **REQUIRED NEXT:** `claudehut:write-plan`.
