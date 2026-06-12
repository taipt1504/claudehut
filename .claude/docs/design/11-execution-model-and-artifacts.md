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

| Phase          | Skill runs                | Heavy work                                                                                                                                         | User gate (interactive only)      | State write (main)                               | Native tasks (main)                                         |
| -------------- | ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------- | ------------------------------------------------ | ----------------------------------------------------------- |
| **Discover**   | main                      | explorer ∥ reuse-scanner (one message, Agent tool)                                                                                                 | —                                 | set-reuse-scan (+ creates task dir)              | —                                                           |
| **Brainstorm** | main                      | brainstormer (Agent tool); consumes Discover output                                                                                                | AskUserQuestion: choose approach  | set-enforcement                                  | —                                                           |
| Spec           | main (writes spec itself) | —                                                                                                                                                  | AskUserQuestion: **approve spec** | set-spec **after approval**                      | —                                                           |
| Plan           | main                      | claudehut-planner drafts plan (Agent tool)                                                                                                         | AskUserQuestion: **approve plan** | set-plan **after approval**, set-phase implement | TaskCreate per plan task + deps                             |
| Implement      | main                      | walks plan **phase by phase**; per-phase `[P]` fan-out (one implementer each, concurrent, worktree) + dependent tasks one each; inline if ≤2 files | —                                 | —                                                | TaskUpdate in_progress/completed at each **phase boundary** |
| Review         | main                      | **selected** auditors in parallel (Agent tool); test-runner + reviewer always; security/perf/db by enforcement-set + diff                          | —                                 | set-outstanding, set-review                      | —                                                           |
| Learn          | main                      | claudehut-learner (Agent tool)                                                                                                                     | —                                 | set-phase learn                                  | —                                                           |

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
- Implement → main thread marks every task in a phase `in_progress` **before** dispatching that phase's batch
  and `completed`/`blocked` **after** the batch reconciles (verify green — from its run or the implementer's
  returned per-task status block). Updates land at **phase boundaries**, not mid-batch: subagents have no task
  tools, and a blocking single-message dispatch cannot report partials (the accepted trade for not paying
  background-dispatch overhead). The implementer itself works from `plan.md`.
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
    ├── reuse-scan.md      # Discover
    ├── spec.md            # Spec (from template)
    ├── plan.md            # Plan (from template; T-001… table = durable breakdown)
    └── review.md          # Review (merged auditor findings + final verdict)
```

- `NNNN` = zero-padded next integer over `tasks/`; slug = kebab task name. Created by Discover (first
  artifact). Every later phase writes into the same dir — one place per task, trivially archivable.
- **Artifact length budgets (Issue 3 — docs are dispatch tables a reviewer scans in ≤5 min, not transcripts):**

  | Artifact        | Budget     | Format contract (template)                                                                                                                    | Measured before              |
  | --------------- | ---------- | --------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------- |
  | `reuse-scan.md` | ≤400 words | Summary table first; Evidence only for questionable rows (`skills/discover/references/reuse-scan-template.md`)                                | 1,178 words, ~60% repetition |
  | `spec.md`       | ≤800 words | Right-sized sections; §9 ≤80 words (no Brainstorm score echo); §12 rules as a table (`skills/write-spec/references/spec-template.md`)         | 1,430 words                  |
  | `plan.md`       | ≤500 words | `Test first` = `Class#method` ≤60 chars; `Minimal change` ≤30 words; OQ resolved once in §1 (`skills/write-plan/references/plan-template.md`) | 1,477 words, 609-char cells  |
  | `review.md`     | ≤450 words | Severity-tagged findings table (already the reference quality — unchanged)                                                                    | 420 words ✓                  |

- Gates unchanged: `canon()` / `exists_canon()` already require only "under `.claude/claudehut/`" — the
  layout is convention, the gate is the enforcement. Old flat paths remain gate-valid (no breakage on
  existing projects); new tasks use `tasks/`.
- Review now persists `review.md` (it previously left no artifact) — closes the evidence loop.

## 5. What changed where (v0.4)

**Decision reversal (v0.4):** explore + reuse-scan were previously part of Brainstorm (phase 1). They are now
**Discover** (a new phase 1), and Brainstorm is now phase 2 with generic, domain-agnostic ideation. The
reversal reason: folding discovery into Brainstorm over-fit it to a single stack and killed creative breadth.

| Area                            | Change                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| ------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `skills/discover/`              | **NEW**: Reuse Iron Law; dispatches explorer ∥ reuse-scanner in one message; writes reuse-scan artifact; `set-reuse-scan`; required every tier                                                                                                                                                                                                                                                                                                                                                      |
| `skills/brainstorm`             | **REVERSAL**: no longer dispatches explorer or reuse-scanner — those are Discover's job. Now dispatches only brainstormer (generic ideation); consumes Discover's context + reuse DECISION; builds enforcement set                                                                                                                                                                                                                                                                                  |
| `skills/claudehut-workflow`     | Updated: 7 phases; Phase-0 triage (trivial/small/full); tier→phase table; law 3 now refs `claudehut:discover`                                                                                                                                                                                                                                                                                                                                                                                       |
| `skills/review`                 | **v0.4**: dynamic reviewer selection — test-runner + reviewer always; security/perf/db selected by enforcement-set + diff; no-DB change does NOT spawn db-reviewer                                                                                                                                                                                                                                                                                                                                  |
| `scripts/gate-write.sh`         | **v0.4**: tier-aware — Rail 1 (all tiers): reuse-scan; Rail 2 (trivial/small): fast-lane bound (≤2 files, no security/auth/migration); Rail 3 (full): spec+plan                                                                                                                                                                                                                                                                                                                                     |
| `bin/claudehut-state`           | **v0.4**: `set-complexity` subcommand added; `complexity` field in schema (default `full`); default `phase` is now `discover`                                                                                                                                                                                                                                                                                                                                                                       |
| `scripts/bootstrap.sh`          | Arms initial state with `phase=discover` (was `brainstorm`); understand-anything flag now refs Discover                                                                                                                                                                                                                                                                                                                                                                                             |
| `agents/claudehut-brainstormer` | **v0.4 review round**: fixed 6-step ideation pipeline the agent ALWAYS follows (FRAME weighted criteria → DIVERGE ≥6 raw candidates via lens rotation + mandatory wildcard, judgment deferred → CLUSTER to 2–4 structurally distinct → SCORE weighted matrix, dominated options out → PREMORTEM both finalists → RECOMMEND) + 5 hard rules. Research-grounded: Double Diamond second diamond, Osborn deferred judgment, Pugh matrix, Klein premortem, LLM mode-collapse mitigation. `effort: xhigh` |
| model policy (all agents)       | **opus** for critical-reasoning phases: brainstormer (`xhigh`), planner, security-auditor. **sonnet** default for the rest (learner haiku→sonnet; implementer explicit sonnet — implementation is mechanical when the plan is hyper-specified)                                                                                                                                                                                                                                                      |

## 5b. What changed where (v0.3)

| Area                                          | Change                                                                                                    |
| --------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| `skills/write-spec`                           | template + approval gate before `set-spec`; writes `tasks/<id>/spec.md`                                   |
| `skills/write-plan`                           | de-forked; dispatches planner; approval gate before `set-plan`; TaskCreate mirror                         |
| `skills/brainstorm`                           | main thread records state (agents return data); creates `tasks/<id>/`; scan at `tasks/<id>/reuse-scan.md` |
| `skills/implement`                            | explicit inline-vs-dispatch rule; TaskUpdate mirroring; reads plan from task dir                          |
| `skills/review`                               | persists `tasks/<id>/review.md`                                                                           |
| `skills/capture-learnings`                    | de-forked; dispatches learner; main closes phase                                                          |
| `skills/claudehut-workflow`                   | execution-model table; law 6 updated to task-dir layout                                                   |
| `agents/` planner·scanner·learner·implementer | path + return-contract updates; no state writes anywhere                                                  |
| `bin/claudehut-init`                          | creates `tasks/` (not `specs/` `plans/`)                                                                  |
| `scripts/verify-subagent.sh`                  | artifact globs → `tasks/*/…`                                                                              |
| `evals/`                                      | structural assertions updated per group                                                                   |

## 6. Parallel execution + worktree lifecycle

Driven by measured friction: (a) the worktree isolation boundary makes content-in-prompt mandatory for the _uncommitted_ in-flight plan/spec (v0.4.0: ClaudeHut sets `worktree.baseRef=head` so worktrees fork from the **current branch HEAD** — committed prior-phase work IS carried in; the default `origin/HEAD` base previously hid the in-session spine and forced dependent phases inline); (b) native provides no auto-merge + changed worktrees persist after a subagent exits, leaving orphan branches; (c) a blocking `SubagentStop` without the `stop_hook_active` cap produced infinite holds. This section is the authoritative record of root causes, the tiered dispatch model, the lifecycle helper, and the cap fix. Cross-referenced from [01 §4.1](./01-agentic-workflow.md#41-concurrency-and-worktree-isolation-collision-safe-state).

### Root causes (measured, not theoretical)

| Issue                                                                                      | Root cause                                                                                                                                                                                                     | Evidence                                                                                                                                                                                       |
| ------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Uncommitted main-tree artifacts (in-flight plan/spec, state) not visible inside a worktree | `isolation: worktree` (with `baseRef=head`) forks from the **current branch HEAD** — committed prior-phase code IS present, but **uncommitted** files (the live plan.md, `state/`) are not                     | Confirmed by live-usage: implementer tried to read `tasks/…/plan.md`, found nothing                                                                                                            |
| **Dependent later phases forced inline** (lost fan-out)                                    | with the default `origin/HEAD` base, a phase depending on in-session-only commits (the spine, committed to the feature branch but unpushed) could not see them in a worktree → model correctly ran them inline | Real party-ms 0007: Phase-3's six `[P]` handlers (all dep T-001/T-005/T-006) ran inline; branch was 15 commits ahead of origin. **Fixed by `baseRef=head`** + commit-before-dependent-dispatch |
| Agent branches persist after `DONE` — orphan worktrees accumulate                          | Native `isolation: worktree` auto-removes the worktree **only if the branch has no commits beyond the base** — a real implementation commit prevents auto-removal                                              | Verified: directories remain under `.claude/worktrees/` after dispatch                                                                                                                         |
| No auto-merge — parallel branches exist, repo diverges                                     | Native worktrees give isolation; they do not merge back. After a parallel fan-out the main tree still sees zero of the parallel agents' work                                                                   | Native behavior: `git merge` must be called explicitly per branch                                                                                                                              |
| Blocking `SubagentStop` without the `stop_hook_active` cap = infinite hold                 | `verify-subagent.sh` blocked a subagent ("continue working") when an artifact was mispathed; without the cap the subagent loops forever, presenting as a hang — the **measured hang vector**                   | Fixed in `scripts/verify-subagent.sh`: exits 0 (fail-open) when `stop_hook_active = true`, matching the same cap `gate-done.sh` applies                                                        |

### Phase-walk orchestration (Issue 1 fix, v0.3.2)

**The main thread walks the plan PHASE BY PHASE — it never hands the whole plan to one implementer.** Real
plans are _phased and mixed_ (a sequential setup phase, a domain phase with several independent tasks, an API
phase…). The earlier model was a **binary** decision tree (all-`[P]` → parallel, else → one implementer for
the whole dependent chain); facing a realistic mixed plan it had no orchestration path and collapsed to a
single opaque implementer — measured in real party-ms usage (12-task / 8-phase / 2-`[P]` plan dispatched as
one agent; frozen task list). The fix replaces it with a per-phase loop: phases run in order (the sequential
spine), and **within each phase** the execution mode is chosen **per task**:

| Within-phase mode        | When                                                           | Worktree                | Merge needed                               |
| ------------------------ | -------------------------------------------------------------- | ----------------------- | ------------------------------------------ |
| **Inline**               | ≤ 2 files, no migration                                        | no                      | no                                         |
| **Single implementer**   | a dependent task in this phase                                 | yes                     | yes (one reconcile call)                   |
| **`[P]` parallel batch** | the phase's `[P]`/independent tasks, gated by `check-disjoint` | yes, one per `[P]` task | yes, serialized (one reconcile per branch) |

**The planner drives the parallelism**: it groups every multi-task plan into phases and marks `[P]` on
**every** intra-phase-independent task (not just one — under-marking serializes Implement). The main thread
then fans out exactly the `[P]` set per phase.

**The safety gate is deterministic, not LLM judgment.** The `[P]` markers in the plan are a SOFT instruction; the actual safety boundary is `bin/claudehut-worktree check-disjoint <plan.md>`, which is **phase-aware** (v0.3.2): it checks file-disjointness **within each phase** (the unit the main thread fans out) and prints the **per-phase batch schedule** the skill follows. A file reused across _different_ phases is safe (those tasks never run concurrently) — a global check false-positived here and serialized legitimate parallelism, reproducing Issue 1 through the back door. Exit 0 = every phase's `[P]` Files are pairwise disjoint; exit 2 = a _within-phase_ overlap (run that phase's tasks sequentially; other phases still parallelize). Superpowers forbids naive parallel implementation; this check is the enforcement.

**Single-message dispatch (soft, best-effort).** All `[P]` Agent tool calls are issued in **one message** — the native concurrency trigger (multiple tool_use blocks in a single response run concurrently; one call per message runs serially). This is a **soft/best-effort** speedup instruction: correctness never depends on concurrency being achieved. Max 3 concurrent implementers per dispatch.

**Content-in-prompt rule (hard).** The worktree forks from the current branch HEAD (`baseRef=head`), so **committed** prior-phase code IS present — build on it. But the in-flight `plan.md`/`spec.md` are **uncommitted** at dispatch time, so the dispatch prompt must carry plan rows **verbatim** (goal, files, test-first, minimal change, verify) plus acceptance criteria and an exclusive file-ownership list. Never pass a path to `tasks/…/plan.md` — that uncommitted file does not exist inside the worktree.

**Commit-before-dependent-dispatch (hard, v0.4.0).** Because worktrees fork from current HEAD, every prior phase must be **committed on the feature branch before the next phase dispatches**: reconcile commits the worktree branches; an **inline** phase (sequential spine, ≤2-file task) must be `git commit`-ed explicitly. Otherwise the next phase's worktrees fork from a HEAD missing the inline work → they can't build on it → forced back to inline. This is the discipline that makes `baseRef=head` actually deliver the dependent-phase fan-out.

**Live verification of the Issue-1 fix (v0.3.2, `evals/parallel-dispatch-probe.sh`, demonstrated-once on opus).** The dispatch decision is made by the **main thread**, which in real sessions is Opus 4.8 — so the probe runs `--model opus` (implementers stay sonnet via frontmatter), pre-gated to start _at_ Implement, with a NEUTRAL prompt (never says "parallel"/"one message"; the skill must decide). Detector is msg-id-**grouped** (per-event counting undercounts — a prior artifact). Result on a substantial 3-task / 2-phase plan: `fanout_max_per_msg=2`, `implementers_total=2`, `check_disjoint_used=1`, `TaskCreate=3 / TaskUpdate=7` — the main thread ran the phase-aware `check-disjoint`, dispatched **both Phase-1 `[P]` implementers in one message** (worktree isolation), serialized the reconcile, marked tasks in_progress→completed at the phase boundary, then ran Phase-2 inline and swept to zero orphans. Caveat (honest): n=1, soft by the project's standard; and a `--model sonnet` + trivial-file-creation run **inlined** (legitimate for ≤2-file work, but it conflated "parallel" with batching its own Writes) — the fan-out is demonstrated for opus + dispatch-worthy work, not guaranteed for every model/size. The deterministic rails (phase-aware `check-disjoint` + schedule, template/planner layout) are the guarantees; the fan-out itself remains a soft behavior.

**Live verification of the spine-dependent fan-out (v0.4.0, `evals/parallel-dispatch-spine-probe.sh`, opus, demonstrated-once).** Tests the exact 0007 failure class: Phase A commits `BaseProcessor` on the feature branch (local-only, branch 1-ahead of origin), Phase B has two `[P]` handlers that **depend on and `extend BaseProcessor`**. Result with `worktree.baseRef=head`: `fanout_max_per_msg=2`, both implementers returned **DONE**, **both handlers `extend BaseProcessor`** (i.e. the worktree saw the committed spine), reconciled onto the feature branch — fan-out of a dependent phase, end-to-end. This run also **earned two real bug finds** (the verification's payoff): (1) the probe's first attempts wrote `settings.json` before `mkdir .claude` so `baseRef` wasn't set → an accidental **negative control**: without `baseRef=head` the spine-dependent implementer **BLOCKED** (couldn't see `BaseProcessor`), directly confirming the root cause; (2) `check-disjoint` mis-parsed **non-digit phase labels** (`Phase A/B`) and `[P]` rows before the first digit heading — an uninitialized `phase` key reported "no `[P]` found" → the model _correctly_ inlined per the wrong schedule. **Fixed** (`BEGIN{phase=0}` + alphanumeric-label regex) and locked with two `worktree-tests` cases; only after that fix did the fan-out reproduce. Caveats (honest): n=1, soft; the headless Learn-phase write to `learnings.jsonl` hit a sensitive-file permission gate (a `--print`-mode artifact, not a plugin defect — interactive use approves it).

### `bin/claudehut-worktree` — four subcommands

Scope-guarded to `.claude/worktrees/` (the managed root where `isolation: worktree` creates them). Every mutating operation validates its target is strictly under that root — this tool can never touch user worktrees elsewhere, and never runs a bare destructive prune first.

| Subcommand                            | Purpose                                                                                                                                                                        | Exit codes                                                 |
| ------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------- |
| `status`                              | Lists managed worktrees: branch, dirty?, merged?                                                                                                                               | 0                                                          |
| `check-disjoint <plan.md>`            | **Phase-aware**: groups `[P]` rows by phase heading, checks Files disjointness _within each phase_, prints the per-phase batch schedule; exit 2 only on a within-phase overlap | 0 = safe, 2 = unsafe                                       |
| `reconcile <branch> [--test-cmd CMD]` | Serialized `--no-ff` merge of ONE agent branch; refuses dirty main tree; on conflict aborts cleanly; if CMD given, runs it and on red tests rolls the merge back (ORIG_HEAD)   | 0 = merged, 2 = conflict-aborted, 3 = red-test-rolled-back |
| `sweep`                               | Removes ONLY worktrees that are clean AND merged/unchanged (+ deletes their branch), then prunes stale metadata                                                                | 0                                                          |

**Serialized reconcile — never batch-merge.** As implementers return `DONE (branch: <name>, commit: <sha>)`, merge **one branch at a time** via `reconcile`. 25–32% of parallel AI branches conflict; batch-merging silently clobbers work. After the last merge, `sweep` removes only clean+merged managed worktrees — zero orphans, nothing outside `.claude/worktrees/` touched.

**Live verification record (superseded — see the benchmark below).** Initial 2-run check verified: no hang,
commit-before-DONE honored, `reconcile` 2/2 + `sweep` 2/2, zero remaining worktrees. Its claim that
single-message dispatch "did not reproduce headless" was a **measurement artifact**: the dispatch-shape
detector counted Agent calls per stream-json _event_, but the stream emits each tool_use as its own assistant
event sharing one `message.id` — undercounting multi-call messages as serial.

**Benchmark record (`evals/bench/parallel-bench.sh`, epoch-file ground truth, overlap-gated).** Corrected
findings across the probe + 9-trial matrix + shape-confirm run:

- **Single-message multi-dispatch (A1) DOES fire headless and DOES produce true concurrency** — message-id-
  grouped shape showed 2 Agent calls per message; epoch intervals overlapped in 6/6 concurrent-instruction
  trials (T1+T2), with **consistent ~26s orchestration overhead**. Its raw wall variance was _agent-duration_
  variance, not the lever. Real-work T2: ≈1.77× speedup at cost parity (n=2, directional).
- **`background: true` (A2): works (3/3 concurrent; headless main thread waits-then-reconciles) but carries
  ~56s overhead (≈2× A1), and is REJECTED for write/implementation agents** — ecosystem bug record (silent
  output loss, silent Write/Edit/Bash auto-deny with false success, a parallel-worktree cleanup race that
  destroyed a `.git` — all closed "not planned") plus zero official Anthropic plugins shipping background
  write agents. A2 stays **open for read-only fan-out** (review auditors): its concurrency is independent of
  the model's batching choice — a risk later **measured and downgraded**: at ~65k input tokens the review
  skill still batched 5 Agent calls in one message (single qualitative run; cannot be hard-guaranteed; serial
  fallback stays correct). Parallel-dispatch guidance now also lives on the always-loaded surfaces (workflow
  skill + MEMORY.md slice), and skills dispatch agents by qualified type (`claudehut:claudehut-…` — an
  unqualified 5-agent batch was measured wasting a full re-dispatch round). The scoped A2 read-only test
  (background auditors) is **CLOSED**: 5/5 reports returned with no silent loss, but no advantage over A1 —
  slightly slower, and A1 batching held in every measurement. A1 everywhere. Full decision record:
  `evals/bench/BENCH-REPORT.md` — **A1 approved as the plugin's write-fan-out lever (user, 2026-06-04)**.
- **Sequential baseline (A0)**: 0/3 overlap (correctly serial). One A0 trial had an agent die mid-task;
  `sweep` correctly **kept** its dirty worktree (retain-evidence-by-design), removed nothing else.
- Caveat: agents sometimes skipped the fixed-duration work block (soft instruction), so wall-clock ratios are
  approximate; the **overlap** numbers are ground truth (written by the agents as epoch files, committed).
  The hang _mechanism_ (Gradle build in a blind worktree) remains not reproduced; `--no-daemon` +
  content-in-prompt are design mitigations.

**Commit-before-DONE contract.** A `claudehut-implementer` must commit its work (`git add -A && git commit`) before returning `DONE` — an uncommitted worktree strands the work as an orphan because the main thread reconciles by merging the **branch**, not by reading uncommitted files. The status line `DONE (branch: <name>, commit: <sha>)` is the handshake.

**BLOCKED-immediately rule.** If a precondition is missing or a test cannot be made to pass, the implementer returns `BLOCKED: <reason>` immediately — never waits, never retry-loops. A waiting subagent presents as a hang.

### The `stop_hook_active` cap fix

`scripts/verify-subagent.sh` now reads `stop_hook_active` from its input JSON before checking artifact presence. When `stop_hook_active = true` it exits 0 (fail-open) instead of blocking. Without this cap, a missing or mispathed artifact causes `SubagentStop` to re-issue the block, the native platform re-runs the subagent, the artifact is still absent → the cycle repeats until the session is killed externally — the **infinite hold / hang vector**. The cap is the same mechanism `gate-done.sh` uses for the Review loop; `verify-subagent.sh` now applies it identically.

### Eval coverage

`evals/worktree-tests.sh` — 11 deterministic shell tests; no Claude needed. Covers: `check-disjoint` pass + overlap-refused, `sweep` scope-guard + clean/dirty/unmerged/outside-root cases, `reconcile` merge + conflict-abort (exit 2, tree restored) + red-test rollback (exit 3) + green-test kept, dirty-main-tree refused.
