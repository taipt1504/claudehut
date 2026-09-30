# ClaudeHut — session digest

You are operating under ClaudeHut. The codebase is pre-indexed. The workflow is **7 phases** — Discover →
Brainstorm → Spec → Plan → Implement → Review → Learn — and you are always in exactly one. Full orchestrator
(flow diagram, rationale, dispatch detail): invoke `/claudehut:claudehut-workflow`.

## Phase 0 — triage EVERY task

| Tier | When | Phases run | Skips |
|------|------|------------|-------|
| **trivial** | comment/doc/rename/config value; no logic change | Discover (inline) → Implement → Review (min) | Brainstorm, Spec, Plan |
| **small** | ≤2 files, no new component, no security/auth/migration surface, one obvious approach | Discover (inline) → Implement → Review → Learn | Brainstorm, Spec, Plan |
| **full** (default) | new component, multi-file, architectural, security/auth/migration, OR ≥2 viable approaches | all 7 | — |

After 0b open the task: `claudehut-state --session ${CLAUDE_SESSION_ID} start --route light|full --profile <p>
--slug <name>` (trivial/small → light). Use the task dir it prints. Already open for this request → no 2nd
start; another session's task → `resume <id>`. Task done (Learn, or Review/`set-findings` when Learn is
skipped) → `end --status done`. Tier by the **hardest question**, not diff size. A `small` task still names
≥2 approaches + the one chosen, in one line. The reuse-scan, test-first, and a Review pass are never skipped
in any tier. Unsure → **full**.

## Phase 0b — profile (task SHAPE, orthogonal to size)

`--profile feature|bugfix|audit|investigation|migration` on `start`. The deliverable decides what "done"
means: feature/bugfix/migration → `review==pass`; **audit/investigation → a `findings.md` recorded with `set-findings`, not code**. migration always draws
db + perf reviewers; audit always draws the security-auditor.
A shape change mid-flow → `set-profile <new>` on the open task; after it finished (findings recorded, review
`pass`, phase `learn`) it is a new request → `start --profile <new>` (set-profile/set-route there record nothing).

## The laws (non-negotiable)

1. **Skill-first** — before responding or acting, check whether a ClaudeHut skill applies.
2. **1% rule** — if there is even a 1% chance a skill or rule applies, you ABSOLUTELY MUST invoke it. This is
   how the enforcement set is built, and it drives which reviewers Review spawns.
3. **Reuse-first** — never write new code before the reuse-scan step in `claudehut:discover` (recorded,
   required in every tier).
4. **Test-first** — never write production code before a failing test (`claudehut:implement`).
5. **Compliance-first** — never claim done before `claudehut:review` reports zero outstanding (evidence-checked).
6. **Canonical store** — every artifact of a task lives in
   `${CLAUDE_PROJECT_DIR}/.claude/claudehut/tasks/NNNN-<slug>/`. Off-path artifacts are invisible to claudehut-state,
   to memory, and to the next session.
7. **Main thread orchestrates** — skills own the user gates (`AskUserQuestion`), the state writes, and the task
   mirror; subagents do isolated work and return data. They never write state and never ask the user.

Violating the letter of these laws is violating the spirit of them.

## Phase → skill map

| # | Phase | Invoke | Tiers | Produces |
|---|-------|--------|-------|----------|
| 1 | Discover | `claudehut:discover` (explorer ∥ reuse-scanner on full; trivial + small: inline, no dispatch) | all | `reuse-scan.md` + reuse DECISION |
| 2 | Brainstorm | `claudehut:brainstorm` | full | `brainstorm.md` + enforcement set |
| 3 | Spec | `claudehut:write-spec` | full | `spec.md` |
| 4 | Plan | `claudehut:write-plan` | full | `plan.md` (T-xxx) + `plan-review.md` |
| 5 | Implement | `claudehut:implement` | all | code + tests (test-first) |
| 6 | Review | `claudehut:review` (selected auditors) | all | `review.md`; loops until outstanding empty |
| 7 | Learn | `claudehut:capture-learnings` | full + small | `learnings.jsonl` + updated index |

Announce each phase: *"Using ClaudeHut &lt;skill&gt; (phase N)"*. Dispatches with no data dependency between them
go in **one message** (they run concurrently); dispatch plugin agents by qualified type
`claudehut:claudehut-<name>`. Record transitions on the main thread only:
`claudehut-state --session ${CLAUDE_SESSION_ID} set-phase <name>`.

**REQUIRED NEXT:** triage the request (Phase 0), then begin at phase 1 — invoke `claudehut:discover`. Do NOT
jump to Implement.
