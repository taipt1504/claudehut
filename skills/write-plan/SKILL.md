---
name: write-plan
description: Use in the Plan phase after the spec is approved - dispatches the planner agent to draft the executable plan from the standard template (decision summary, T-xxx task breakdown with test-first + verify per task), gets the user's approval, records the plan (opening the write gate), and mirrors the breakdown into Claude Code's native task list. Runs inline on the main thread (it owns the approval gate, the state write, and the task mirror).
allowed-tools: Read Grep Glob Bash Agent AskUserQuestion TaskCreate TaskUpdate
---

# Write Plan (Plan phase)

Convert the approved spec into an executable, test-first plan. Runs **inline on the main thread** — the
planner agent does the drafting in isolation; this skill owns the user gate, the state write, and the native
task mirror (none of which a subagent can do).

## Process

1. **Dispatch `claudehut:claudehut-planner` (Agent tool)** to draft the plan. The task dir is **derived from the
   recorded spec path** (`dirname` of the `set-spec` path) — never recompute `NNNN`; one task = one dir.
   Give the planner: the spec path (`tasks/NNNN-<slug>/spec.md`), the reuse-scan path (same dir), the
   brainstorm path (same dir, if it exists), and the template at `references/plan-template.md`. Tell it to
   fill **§3 Implementation Flow** and a **per-task Sketch** for behavior tasks, **right-sized to the tier**
   (full = flow + sketch each behavior task; small/bugfix/refactor = short flow + sketch only where control
   flow is non-obvious).
   It writes the draft to the canonical path
   `${CLAUDE_PROJECT_DIR}/.claude/claudehut/tasks/NNNN-<slug>/plan.md` and returns the path + a summary.
   It does NOT write state — that is this skill's job, after approval.
2. **Check the draft** before showing it: §1 restates the spec's decision; §3 Implementation Flow traces the
   change end to end; every behavior task in the T-xxx table names its **failing test first** and an exact
   **verify command**; dependencies are explicit. Send it back to the planner with concrete feedback if not.
   (**`claudehut-state set-plan` REJECTS a plan with no `| T-xxx` rows** — a freeform plan will not open the
   write gate.)
3. **Dispatch `claudehut:claudehut-plan-reviewer` (Agent tool)** — the doc gate, BEFORE the user sees the
   plan. It judges the plan against the spec (coverage of every AC/FR, no-placeholder scan, sketch
   implementability, reuse honored) and returns `APPROVE` or `REVISE` with concrete fixes. On `REVISE`, route
   its items back to the planner and re-dispatch the reviewer until `APPROVE`. This is the structural answer
   to "the plan wasn't reviewable" — the plan is a contract, so an adversarial reader checks it first. (Skip
   ONLY on a `-p` run with no Agent budget; say so in the plan header.)
4. **Get approval (this is what opens the write gate — not before).** In interactive use, call the
   **`AskUserQuestion` tool**: present the decision + the T-xxx list (id + goal, one line each) and offer
   **Approve** / **Request changes** (revise via the planner and re-ask). On a non-interactive run (`-p`),
   proceed with the draft and record `approval: non-interactive run — proceeded with draft` in the plan header.
5. **Only after approval**, record it (this unlocks the `PreToolUse` write gate):

   ```
   claudehut-state --session ${CLAUDE_SESSION_ID} set-plan .claude/claudehut/tasks/NNNN-<slug>/plan.md
   ```

6. **Mirror the breakdown into the native task list** so progress is visible in Claude Code's task panel:
   one **`TaskCreate`** per T-xxx row — `subject: "T-001: <goal>"`, `description`: files + test-first +
   verify + req-ref, `activeForm`: present-continuous — then **`TaskUpdate addBlockedBy`** wiring the
   Depends-on column. The native list is a **per-session live mirror**; `plan.md` stays the durable source
   of truth (a resumed session re-mirrors pending tasks from `plan.md`).
7. Enter Implement: `claudehut-state --session ${CLAUDE_SESSION_ID} set-phase implement`.

**REQUIRED NEXT:** `claudehut:implement` (test-first; the enforcement-set rules auto-load by path).
