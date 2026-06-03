---
name: write-spec
description: Use in the Spec phase after an approach is chosen in Brainstorm and before planning - produces the implementation spec (chosen approach, acceptance criteria, enforcement manifest) that the implementation and Review are measured against. Subsumes the old ADR.
allowed-tools: Read Grep Glob Write
---

# Write Spec (Spec phase)

Turn the chosen approach into the **contract** the implementation and Review are graded on.

## Process

1. Pick the spec id: `NNNN` = (highest existing number in `.claude/claudehut/specs/`) + 1; slug = kebab-case of the task.
2. Write the spec to the **absolute canonical path** `${CLAUDE_PROJECT_DIR}/.claude/claudehut/specs/NNNN-<slug>.md` — NOT a bare `specs/` or `.claudehut/` path (`claudehut-state set-spec` rejects non-canonical paths, and the write gate verifies the file exists under `.claude/claudehut/`). Include:
   - **Context** — the task + relevant codebase facts from Explore.
   - **Chosen approach** — what will be built and why (this is the decision rationale; the spec subsumes the old ADR).
   - **Acceptance criteria** — concrete, checkable.
   - **Enforcement manifest** — the skills + rules from the enforcement set (Brainstorm) that Review will audit.
   - **Rejected alternatives** — one line each.
3. Record it:

   ```
   claudehut-state --session ${CLAUDE_SESSION_ID} set-spec .claude/claudehut/specs/NNNN-<slug>.md
   ```

Do NOT write production code yet — the write gate stays closed until a plan exists.

**REQUIRED NEXT:** `claudehut:write-plan`.
