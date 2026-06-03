# 11 — Execution model + artifact organization (v0.3 redesign)

Driven by live-usage review (ewallet workspace): inconsistent spec/plan structure, no decision/breakdown in
plans, no user approval at Spec/Plan, skills-vs-agents mixing, flat evidence dir that doesn't scale.

## 1. The execution model (one rule)

> **Skills run on the main thread and own orchestration: user gates (`AskUserQuestion`), state transitions
> (`claudehut-state` via Bash), and native task mirroring (`TaskCreate`/`TaskUpdate`). Subagents do isolated
> work and return data — they never write state, never ask the user.**

Why: subagents cannot use `AskUserQuestion` (main-loop-only) and most have no `Bash` (cannot run the state
CLI). The pre-v0.3 skills told Bash-less agents to run `claudehut-state` (scanner, brainstormer, learner) and
forked `write-plan` wholesale into the planner — the visible "mixing". Fork vs Agent-dispatch are both native;
the bug was orchestration duties assigned to contexts that can't perform them.

### Per-phase matrix

| Phase | Skill runs | Heavy work | User gate (interactive only) | State write (main) | Native tasks (main) |
|---|---|---|---|---|---|
| Brainstorm | main | explorer → reuse-scanner → brainstormer (Agent tool) | AskUserQuestion: choose approach | set-reuse-scan, set-enforcement | — |
| Spec | main (writes spec itself) | — | AskUserQuestion: **approve spec** | set-spec **after approval** | — |
| Plan | main | claudehut-planner drafts plan (Agent tool) | AskUserQuestion: **approve plan** | set-plan **after approval**, set-phase implement | TaskCreate per plan task + deps |
| Implement | main | claudehut-implementer (worktree) for multi-file; inline if ≤2 files | — | — | TaskUpdate in_progress/completed per step |
| Review | main | 5 auditors in parallel (Agent tool) | — | set-outstanding, set-review | — |
| Learn | main | claudehut-learner (Agent tool) | — | set-phase learn | — |

`context: fork` removed from `write-plan` and `capture-learnings` — every phase skill is a main-thread
orchestrator dispatching its agent(s). Uniformity is the point: one mental model, no per-phase surprises.

**Enforced approval:** `set-spec` / `set-plan` run only AFTER the user approves via AskUserQuestion — so the
`PreToolUse` write gate stays hook-locked until approval. Non-interactive (`-p`) fallback: proceed with the
draft (AskUserQuestion unavailable), state so in the doc header.

## 2. Native task mirroring (visibility, not record)

The native task list (TaskCreate/TaskUpdate) is **session-scoped and ephemeral** — it is the live progress
view in Claude Code's task panel, NOT the durable record. The durable record is `plan.md`'s task table
(T-001…). Rules:
- Plan approval → main thread `TaskCreate` one native task per plan task (`subject: "T-001: <goal>"`), wires
  `addBlockedBy` from the Depends-on column.
- Implement → main thread marks `in_progress` before a step starts and `completed` when its verify command is
  green (from the implementer's per-step report). The implementer itself works from `plan.md`.
- A resumed session re-mirrors pending steps from `plan.md` — never the other way around.

## 3. Spec + plan templates (consistency standard)

Shipped as skill references (preloaded path, copied per task):
- `skills/write-spec/references/spec-template.md` — synthesis of GitHub spec-kit (user stories, GWT
  acceptance, [NEEDS CLARIFICATION]), AWS Kiro (EARS functional requirements), MADR 4.x (decision record),
  Google design docs (goals/non-goals, cross-cutting). Plus the ClaudeHut-specific **enforcement manifest**.
- `skills/write-plan/references/plan-template.md` — spec-kit plan/tasks templates (per-task ID/Files/
  Test-first/Verify/Depends-on/Req-ref, phase grouping, [P] parallel marker) + decision summary at §1
  (the plan surfaces the chosen decision prominently, not a buried link).

**Right-sizing rule (in both templates):** `type: feature` → full template; `type: refactor|bugfix` → reduced
named subset (spec: Problem & Context, Decision Record, Acceptance Criteria, Out of scope, Enforcement
manifest). Consistent = predictable, not maximal — no "N/A" walls on a bugfix.

**Hard enforcement (live-measured necessity):** a smoke run showed soft instructions alone let a freeform
plan through (0 T-rows; write-plan skill skipped). So `claudehut-state` validates structure at record time:
`set-spec` rejects a file with no `## ` sections or no Decision Record; `set-plan` rejects a file with no
`| T-xxx` rows (fail-open when the file is absent — existence stays the write gate's job). A freeform
spec/plan therefore cannot arm the write gate; the deny message routes the model back to the skill + template.

## 4. Evidence organization (scales over time)

```
.claude/claudehut/
├── MEMORY.md  PROJECT.md  LANGUAGE.md  architecture.md      # plane (global, committed)
├── reuse-index.json  learnings.jsonl                        # indexes (global, committed)
├── state/<session>.json                                     # per-session (gitignored)
└── tasks/NNNN-<slug>/                                       # ONE DIR PER TASK
    ├── reuse-scan.md      # Brainstorm
    ├── spec.md            # Spec (from template)
    ├── plan.md            # Plan (from template; T-001… table = durable breakdown)
    └── review.md          # Review (merged auditor findings + final verdict)
```

- `NNNN` = zero-padded next integer over `tasks/`; slug = kebab task name. Created by Brainstorm (first
  artifact). Every later phase writes into the same dir — one place per task, trivially archivable.
- Gates unchanged: `canon()` / `exists_canon()` already require only "under `.claude/claudehut/`" — the
  layout is convention, the gate is the enforcement. Old flat paths remain gate-valid (no breakage on
  existing projects); new tasks use `tasks/`.
- Review now persists `review.md` (it previously left no artifact) — closes the evidence loop.

## 5. What changed where (v0.3)

| Area | Change |
|---|---|
| `skills/write-spec` | template + approval gate before `set-spec`; writes `tasks/<id>/spec.md` |
| `skills/write-plan` | de-forked; dispatches planner; approval gate before `set-plan`; TaskCreate mirror |
| `skills/brainstorm` | main thread records state (agents return data); creates `tasks/<id>/`; scan at `tasks/<id>/reuse-scan.md` |
| `skills/implement` | explicit inline-vs-dispatch rule; TaskUpdate mirroring; reads plan from task dir |
| `skills/review` | persists `tasks/<id>/review.md` |
| `skills/capture-learnings` | de-forked; dispatches learner; main closes phase |
| `skills/claudehut-workflow` | execution-model table; law 6 updated to task-dir layout |
| `agents/` planner·scanner·learner·implementer | path + return-contract updates; no state writes anywhere |
| `bin/claudehut-init` | creates `tasks/` (not `specs/` `plans/`) |
| `scripts/verify-subagent.sh` | artifact globs → `tasks/*/…` |
| `evals/` | structural assertions updated per group |
