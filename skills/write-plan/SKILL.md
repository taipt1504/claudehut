---
name: write-plan
description: Use in the Plan phase after the spec is written - turns the implementation spec into a file-level, executable plan (ordered steps, files to touch, tests to write first, verification commands). Writing the plan is what opens the write gate.
context: fork
agent: claudehut-planner
---

# Write Plan (Plan phase)

Convert the spec into an executable plan that test-first implementation can follow step by step.

## Process

1. Read the spec (`specs/NNNN-<slug>.md`) and the reuse-scan artifact.
2. Write the plan to the **absolute canonical path** `${CLAUDE_PROJECT_DIR}/.claude/claudehut/plans/<task>.md` — NOT a bare `plans/` or `.claudehut/` path (`claudehut-state set-plan` rejects non-canonical paths; the write gate verifies the file exists under `.claude/claudehut/`):
   - Ordered steps; for each: the **failing test to write first**, then the minimal code, files to touch.
   - Verification commands (the exact build/test commands from `PROJECT.md`).
   - For agentic execution, head the plan with: `REQUIRED SUB-SKILL: claudehut:implement`.
3. Record it (this unlocks the `PreToolUse` write gate):

   ```
   claudehut-state --session ${CLAUDE_SESSION_ID} set-plan .claude/claudehut/plans/<task>.md
   ```

**REQUIRED NEXT:** enter Implement — `claudehut:implement` (test-first; the enforcement-set rules auto-load by path). (`claudehut-state --session ${CLAUDE_SESSION_ID} set-phase implement`.)
