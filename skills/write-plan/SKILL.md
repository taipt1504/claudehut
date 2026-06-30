---
name: write-plan
description: Use in the Plan phase after the spec is approved - dispatches the planner agent to draft the executable plan from the standard template (decision summary, T-xxx task breakdown with test-first + verify per task), gets the user's approval, records the plan (opening the write gate), and mirrors the breakdown into Claude Code's native task list. Runs inline on the main thread (it owns the approval gate, the state write, and the task mirror).
allowed-tools: Read Grep Glob Bash Agent AskUserQuestion TaskCreate TaskUpdate
---

# Write Plan (Plan phase)

Convert the approved spec into an executable, test-first plan. Runs **inline on the main thread** — the planner
drafts in isolation; this skill owns the user gate, the state write, and the task mirror (a subagent cannot).

## Flow

```mermaid
flowchart TB
    s(["spec approved (set-spec recorded)"]) --> draft["dispatch claudehut-planner → draft plan.md<br/>(T-rows + §3 flow + per-task Sketch)"]
    draft --> check{"§1 restates decision, §3 traces end-to-end,<br/>every behavior task RED-first + verbatim verify?"}
    check -- "no" --> draft
    check -- "yes" --> rev["dispatch claudehut-plan-reviewer → REFUTE vs spec<br/>writes plan-review.md (SubagentStop blocks empty return)"]
    rev --> verdict{"Verdict == APPROVE?"}
    verdict -- "REVISE (route items back)" --> draft
    verdict -- "APPROVE" --> smart{"full tier AND (≥5 tasks OR sensitive surface)?"}
    smart -- "yes" --> record["set-plan-review APPROVE --evidence plan-review.md<br/>(byte-identical plan; edit forces re-review)"]
    smart -- "no" --> ask
    record --> ask{"interactive? user Approves?"}
    ask -- "Request changes" --> draft
    ask -. "headless -p" .-> bypass(["record approval: non-interactive in header"])
    ask -- "Approve" --> setplan["set-plan plan.md (opens PreToolUse write gate)"]
    bypass --> setplan
    setplan --> mirror["TaskCreate per T-row + TaskUpdate addBlockedBy (Depends-on)"]
    mirror --> phase["set-phase implement → REQUIRED NEXT claudehut:implement"]
```

## Process

1. **Dispatch `claudehut:claudehut-planner`.** Task dir is **derived from the recorded spec path** (`dirname` of
   the `set-spec` path) — never recompute `NNNN`. Inputs: spec, reuse-scan + brainstorm (same dir), template
   `references/plan-template.md`. It writes `…/tasks/NNNN-<slug>/plan.md`; it does NOT write state. (**`set-plan`
   REJECTS a plan with no `| T-xxx` rows**.)
2. **Dispatch `claudehut:claudehut-plan-reviewer`** — doc gate, BEFORE the user sees the plan; it **writes its
   coverage table + `Verdict: APPROVE|REVISE` to `tasks/NNNN-<slug>/plan-review.md`**. Loop on `REVISE`, then
   **record the verdict** (only the main thread writes state):
   ```
   claudehut-state --session ${CLAUDE_SESSION_ID} set-plan-review APPROVE --evidence .claude/claudehut/tasks/NNNN-<slug>/plan-review.md
   ```
   The wire that makes the reviewer fire: **`set-plan` REFUSES a full-tier plan that is substantial (≥5 tasks)
   OR touches a sensitive surface (security/auth/migration) unless `plan_review==APPROVE` is recorded for the
   byte-identical plan** (smart-gate; editing forces re-review via content-hash). Headless `-p`, no Agent budget:
   `claudehut-state set-bypass true` unblocks both set-plan and the write gate (note it in the plan header).
3. **Get approval (this opens the write gate — not before).** Interactive: **`AskUserQuestion`** with the
   decision + T-xxx list, **Approve** / **Request changes**. Non-interactive (`-p`): record `approval:
   non-interactive run — proceeded with draft` in the header. Only after approval (unlocks the `PreToolUse` gate):
   ```
   claudehut-state --session ${CLAUDE_SESSION_ID} set-plan .claude/claudehut/tasks/NNNN-<slug>/plan.md
   ```
4. **Mirror into the native task list**: one **`TaskCreate`** per T-xxx row (`subject: "T-001: <goal>"`,
   `description`: files + test-first + verify + req-ref, `activeForm`: present-continuous), then **`TaskUpdate
   addBlockedBy`** per Depends-on. `plan.md` stays the durable source of truth. Then enter Implement:
   `claudehut-state --session ${CLAUDE_SESSION_ID} set-phase implement`.

**REQUIRED NEXT:** `claudehut:implement` (test-first; the enforcement-set rules auto-load by path).
