---
name: write-spec
description: Use in the Spec phase after an approach is chosen in Brainstorm and before planning - produces the implementation spec from the standard template (EARS requirements, acceptance criteria, MADR decision record, enforcement manifest) and gets the user's approval before recording it. Runs inline on the main thread (it owns the approval gate and the state write).
allowed-tools: Read Grep Glob Write Bash AskUserQuestion
---

# Write Spec (Spec phase)

Turn the chosen approach into the **contract** the implementation and Review are graded on. Runs **inline on
the main thread** — this skill owns a user gate (`AskUserQuestion`) and a state write (`claudehut-state`),
which subagents cannot do.

## Process

1. **Locate the task dir — derive it, never recompute it.** The task dir is the dir of the reuse-scan
   artifact recorded in session state (`dirname` of the `set-reuse-scan --artifact` path) — Brainstorm chose
   `NNNN-<slug>` once and every later phase reuses it. Recomputing "next NNNN" here would scatter one task
   across two dirs. Only if no reuse-scan is recorded at all (you skipped a phase — go back) does a fresh
   task dir get created, in Brainstorm.
2. **Write the spec from the template** at `references/spec-template.md` to the canonical path
   `${CLAUDE_PROJECT_DIR}/.claude/claudehut/tasks/NNNN-<slug>/spec.md` (never a bare `specs/` or
   `.claudehut/` path — `claudehut-state set-spec` rejects non-canonical paths and the write gate verifies
   the file exists under `.claude/claudehut/`). **Right-size by type** (rule is in the template): `feature` →
   all sections; `refactor`/`bugfix` → the reduced subset — no "N/A" walls. Fill from what Brainstorm already
   produced: chosen option → §9 Decision Record, enforcement set → §12 Enforcement Manifest, reuse decision +
   Explore facts → §1.

   Section skeleton (full guidance in the reference — use these exact `##` headings):
   `1. Problem & Context · 2. Goals / Non-Goals · 3. User Story · 4. Functional Requirements (EARS FR-xxx) ·
   5. Acceptance Criteria (GWT AC-xxx) · 6. API Contract Changes · 7. Data Model Changes · 8. NFRs ·
   9. Decision Record · 10. Out of Scope · 11. Open Questions · 12. Enforcement Manifest`
   (reduced subset = 1, 9, 5, 10, 12). **`claudehut-state set-spec` REJECTS a file with no `## ` sections or
   no Decision Record** — a freeform spec will not arm the gate.
3. **Get approval (the gate stays locked until then).** In interactive use, call the **`AskUserQuestion`
   tool**: summarize the spec in 3–5 lines (decision, key ACs, scope) and offer **Approve** / **Request
   changes** (revise and re-ask on changes). On a non-interactive run (`-p`) where `AskUserQuestion` is
   unavailable, proceed with the draft and record `approval: non-interactive run — proceeded with draft` in
   the spec header.
4. **Only after approval**, record it (this is what arms the write gate's spec requirement — do NOT run it
   before the user approves):

   ```
   claudehut-state --session ${CLAUDE_SESSION_ID} set-spec .claude/claudehut/tasks/NNNN-<slug>/spec.md
   ```

Do NOT write production code yet — the write gate stays closed until a plan exists.

**REQUIRED NEXT:** `claudehut:write-plan`.
