# ClaudeHut — Upgrade & Enhancement Plan (toward a measurable "Harness agent")

> **Purpose.** Convert the external review (`docs/REVIEW_ARCHITECTURE.md`, by Claude Mythos + Codex) into a verified, sequenced, file-level implementation plan that moves ClaudeHut toward the user's goal: *an agentic workflow where agents automatically receive a request, decide which skills/rules to apply, execute, and get measurably smarter over time.*
>
> **Method.** Every review finding was **re-audited against the real code** (file:line verdicts, not the review's snapshot) and every load-bearing platform claim was **re-verified against current Claude Code / Anthropic docs** (fetch-and-quote). Where the audit or the docs **diverge from the review**, this plan says so explicitly — that delta is the point.
>
> **Status of inputs:** plugin @ HEAD (post stub-commit / path-canonicalization / `-B` worktree / `CLAUDEHUT_WORKER` work). Platform docs fetched 2026-05-29. Unconfirmed claims are flagged `⚠︎ verify`.
>
> **Verification provenance.** The bulk audit ran as parallel subagents. The claims that *overturn or exceed the reviewers* — the §5.2 reject and the two NEW P0s elevated above the review's own P0s — were additionally **confirmed firsthand**: §5.2 by a live `Agent`-tool subagent sentinel probe, and the two P0s by direct file reads (reviewer tool surfaces + `subagent-stop.sh` + `aggregate-findings.sh`; and a `grep` proving `learnings-recent.md` has no regenerator). Those carry a **(firsthand-verified)** tag in Part A. Everything tagged from the review alone inherits the review's evidence.
>
> **TL;DR (one paragraph).** The review is ~90% correct and high-signal. Re-audit changes three things that matter: (1) the review's **§5.2 "subagents lost CLAUDE.md" is wrong on current docs** — custom subagents *do* load the full memory hierarchy; only `Explore`/`Plan` skip it. (2) The review's headline **§4.2 is a P1 prose bug, not a P0 stall** — no script actually writes the wrong path. (3) Two problems **bigger than anything the review ranked P0** surfaced: the Loop quality gate is a **no-op** (reviewer findings are never persisted, so totals are always zero → every diff "passes"), and the learning channel is a **permanently-empty stub** (`learnings-recent.md` is seeded at init and never regenerated). The honest path to "harness agent that gets smarter" is **not more agents** — it is: fix the two dead subsystems, build an **eval harness** to make claims falsifiable, add **adaptive-depth routing** (the Routing pattern), and replace the static note-dump with **just-in-time relevance retrieval + an outcome-signal usefulness prior** (this *is* "reinforcement," honestly framed).

---

## Table of contents

- [Part A — Audit results (verdicts vs the real code)](#part-a--audit-results-verdicts-vs-the-real-code)
- [Part B — Verified platform facts (and where the review is stale)](#part-b--verified-platform-facts-and-where-the-review-is-stale)
- [Part C — The reconciled vision: what "Harness agent that gets smarter" actually means](#part-c--the-reconciled-vision-what-harness-agent-that-gets-smarter-actually-means)
- [Part D — Sequenced roadmap (file-level, each with a proving test)](#part-d--sequenced-roadmap-file-level-each-with-a-proving-test)
- [Part E — Sequencing rationale & north star](#part-e--sequencing-rationale--north-star)
- [Part F — Open questions for reviewers + unconfirmed claims to verify](#part-f--open-questions-for-reviewers--unconfirmed-claims-to-verify)

---

## Part A — Audit results (verdicts vs the real code)

Verdict legend: **CONFIRMED** (still true), **PARTIAL** (real but narrower/wider than the review), **ALREADY-MITIGATED** (recent work or existing code addresses it), **REJECTED** (contradicted by current code/docs).

### A.1 — Divergences from the review (read these first)

These are the places the re-audit changed the review's conclusion. They reshape the priority order.

| Review § | Review claim | Audit verdict | What's actually true (file:line) |
|---|---|---|---|
| **5.2** | Subagents no longer receive CLAUDE.md (v2.1.84 `tengu_slim_subagent_claudemd`); the mental model is stale | **REJECTED (docs + live probe)** | `sub-agents.md` verbatim: *"CLAUDE.md and memory: every level of the memory hierarchy the main conversation loads"* loads for **every custom subagent**; *only* `Explore`/`Plan` skip it, with **no frontmatter to change that**. The named flags don't appear in docs. **Firsthand probe (2026-05-29, this runtime):** an `Agent`-tool-dispatched custom subagent reported a sentinel (`BANANA_HELICOPTER_42`) present *only* in a temp project's `CLAUDE.md` (not in the dispatch prompt nor the agent def) → CLAUDE.md **does** reach custom subagents here. → The original doc's claim is correct; review §5.2 is stale for this runtime. (Caveat: this does not disprove #40459 at the specific older version it cited — re-verify if you target one.) Keep `dispatch-prompt.sh` redundancy as belt-and-suspenders. |
| **4.2** | Findings-path split → **task can never leave `loop`** (P0) | **PARTIAL → P1 (prose bug)** | No executable code writes the wrong path. `run-verify-parallel.sh:4` *comments* `state/tasks/…` but its body only emits stdout; the real writer `subagent-stop.sh:19` and reader `state.sh:85` **agree** on `.claudehut/findings/<id>-findings.json`. Stale path lives only in `SKILL.md:48`, `references/reviewer-dispatch.md:31`, `references/retry-escalation.md`. Residual: a model that follows the stale prose could mis-aggregate. Real fix = 3-file prose cleanup + a contract test. |
| **4.3** | `high < 3` ships 2 High findings silently (P0) | **CONFIRMED, but practically MOOT today** | `aggregate-findings.sh:17` + `SKILL.md:88` use `high < 3`; verifier prose uses `high == 0` (`verifier.md:24,50,103`); `tests/integration/reviewer-dispatch.sh:97` **enshrines** `high<3`. **But** see 5.4: reviewer findings are never persisted, so `totals` is always `{0,0,0}` and `decision` is always `pass` regardless of the threshold. Fix the rule *and* the no-op underneath it. |
| **new** | — | **NEW P0 (firsthand-verified)** (bigger than 4.3) | **The Loop gate is a no-op.** Verified by reading the files: reviewer `tools:` are `Read,Grep,Glob,Bash,Skill` (no Write), G0 = read-only, and the contract (`reviewer-security.md:24,76,100`) delegates persistence to the SubagentStop hook. But `subagent-stop.sh` writes only `{completed_at}` — the `SubagentStop` event delivers `agent_type`, **not** the reviewer's output text — so `.reviewers[].findings[]` is never populated; `aggregate-findings.sh` always computes zero totals → always `pass`. The marquee "reviewer fleet" produces **no enforced signal** end-to-end. |
| **new** | — | **NEW P0 (firsthand-verified)** (learning channel is dead) | `grep` confirms `learnings-recent.md` is written **only** by `init-project.sh:79` (seed, `[[ -f ]] ||`-guarded) and read by `build`/`plan` `dispatch-prompt.sh`. **No regenerator exists.** Every subagent's "Recent learnings" section has been the `(none yet)` stub since project creation. So §7's "head -200 dump" is, today, "head -200 of an empty file." |
| **5.1** | Path B chosen to dodge skill-preload bug, but Path B has the same gap | **PARTIAL** | Core TDD *is* in the `--append-system-prompt` guardrail (`run-parallel-group.sh:54-69`) + persona via `--agent`. Per current docs, **in-process Task subagents DO preload `skills:`** (`sub-agents.md`), and `--print`-without-`--bare` auto-discovers. So the "same gap" is unproven for `--print --agent`; the confirmed gap is `--bare` and the (unfetched) agent-teams path. This **weakens Path B's rationale** and strengthens the §4.1 flatten-to-Task fix. |

### A.2 — P0 correctness (the pipeline's two headline subsystems don't actually function)

| ID | Verdict | Finding | Evidence | Fix (file-level) |
|---|---|---|---|---|
| **P0-1** (5.4) | CONFIRMED | Reviewer findings never persisted → gate is a no-op + lost-update race | `subagent-stop.sh:19` writes only `completed_at`; `aggregate-findings.sh` reads `.reviewers[].findings[]?` → always empty; concurrent RMW on one file | Each reviewer **writes its own shard** `.claudehut/findings/<id>/reviewer-<name>.json` (Write tool, before returning) with its findings array; `aggregate-findings.sh` merges shards (single reader → no race); `subagent-stop.sh` becomes a completion marker only |
| **P0-2** (4.1) | CONFIRMED (doc-confirmed) | Verifier (a subagent) Task-dispatches reviewer subagents = nested Task→Task; **unsupported** | `verifier.md:5` (`tools: … Task`), `:38,:80-90,:112`; `sub-agents.md` verbatim: *"Subagents cannot spawn other subagents… `Agent(agent_type)` has no effect in subagent definitions"* | **Flatten:** the **orchestrator** (top level) dispatches reviewers directly in one message (Task subagents preload skills + load CLAUDE.md — strictly better than Path B here). Verifier → gate-runner + aggregator only; remove `Task` from its frontmatter |
| **P0-3** (4.3+gap-c) | CONFIRMED | Decision-rule split; test enshrines the weaker rule | `aggregate-findings.sh:17` & `SKILL.md:88` `high<3`; `verifier.md:24/50/103` `high==0`; `tests/integration/reviewer-dispatch.sh:97` asserts `pass` on 1 High | For fintech: standardize on **`high==0`**. Atomically change `aggregate-findings.sh:17`, `SKILL.md:88/96/111`, and the test (expected `fail` for 1 High + add a 0/0 `pass` case) |
| **P0-4** (7.1b) | CONFIRMED | `learnings-recent.md` never regenerated → memory channel is the empty init stub | no writer in any script; `dispatch-prompt.sh:60` reads it; `ARCHITECTURE.md:1935` diagram wrong | Add `regenerate-recent.sh` (top-N JSONL by ts → markdown), call as final step of the learner pipeline (`learn/SKILL.md:52`) |

### A.3 — Test gaps (the structural suite green-lit the bugs above)

| ID | Verdict | Finding | Fix |
|---|---|---|---|
| gap-b (L15) | CONFIRMED | `BLOCKED_TOOLS` omits `Task`, and the awk scans only the **body** (`run-all.sh:1067`), excluding frontmatter — so a subagent declaring `tools: …Task` passes | Add `Task` to the dispatched-subagent block-list; add an assertion that **no** non-orchestrator agent has `Task`/`Agent` in its `tools:` frontmatter |
| gap-a (L11) | CONFIRMED | `reviewer-dispatch.sh` writes via `subagent-stop.sh` and reads a hardcoded path — never round-trips through `state.sh::claudehut_findings_doc` | Assert `claudehut_findings_doc <id>` == the path actually written + read by the aggregator |
| gap-c (L11) | CONFIRMED | Test asserts `pass` on 1 High → rejects the correct `high==0` contract | Change with P0-3 (atomic) |
| L6 / e2e | CONFIRMED | L6 is model-free simulation that **hardcodes** `decision:pass` into `findings.json` (`full-workflow.sh:418-439`), bypassing the real write/read path; real-Claude e2e is 3 opt-in prompts (brainstorm only) | Replace the scripted findings write with a real `aggregate-findings.sh` round-trip; expand e2e past brainstorm |

### A.4 — P1 / P2 (robustness, DX, security) — current status

| ID | Verdict | One-line current status | Fix sketch |
|---|---|---|---|
| 5.3 stop-loop | CONFIRMED | `stop.sh` blocks at `learn` with no escape; relies on platform's external 8-block cap | Parse the platform's **`stop_hook_active`** field and exit 0 when true (built-in escape); add a per-task block counter → downgrade to `systemMessage` after N; also fix 6.4 |
| 5.5 migration-validator | CONFIRMED | The `claudehut-migration-validator` **agent is orphaned** (nothing invokes it); real protection is the passive `paths:` rule (advisory text). `validate-migration.sh` exists but is unwired. Command hooks **cannot** call a Task (`hooks-guide.md` verbatim) | Wire `validate-migration.sh` as a **deterministic** PreToolUse bash gate for `**/db/migration/V*.sql`; deny on non-zero. Demote the agent to a Loop-time reviewer (contextual checks only) or drop it |
| 6.1 loop_max_retries | CONFIRMED | Hardcoded `3`; `plugin.json` knob never read | Read `claudehut-state config phase.loop_max_retries` (default 3) in verifier + dispatch |
| 6.2 destructive allowlist | CONFIRMED | Advertised allowlist never read; regex trivially bypassable; **golden snapshot enshrines the misleading text** (`pre-tool-deny-rm-rf.json:5`) | Reframe as "best-effort speed-bump" (not a sandbox); either implement the allowlist read or remove the claim; update golden |
| 6.3 `state stack` | CONFIRMED | `bin/claudehut-state:43-45` prepends `.` → grep never matches; help says `.json` (file is `.md`). CLI-only; internal callers OK | Drop the dot-prefix for `stack`; fix help; add L2 test |
| 6.4 has_learnings | CONFIRMED | `grep -qF '"task_id":"…"'` matches compact JSON only; a pretty entry → stuck at `learn` (+ 5.3 loop) | `jq -e 'select(.task_id==$id)'` per line; or enforce compact writes |
| 6.5 branch=task-id | CONFIRMED | No `active-task.json` writer exists (readers fall through); rename orphans artifacts; slug collisions undetected; protected-branch lockout | Write a `task_id→branch` pointer at task start; warn on slug drift/collision at init |
| 6.6/6.7 skill budget + 1% rule | CONFIRMED | **Zero `paths:` frontmatter** on any skill → auto-trigger depends entirely on the description budget + the "1% mandate"; rarely-used skills can be silently evicted | Add `paths:` to domain skills; trim descriptions ≤120 chars, key trigger first; set rare skills `name-only`; relax the 1% rule to `paths:`-or-clear-domain-match |
| 6.8 integrations race | CONFIRMED | `session-start.sh` overwrites `integrations.json` (last-writer-wins) | `tmp+mv` atomic write or skip-if-fresh |
| 7.3 memory MCP | CONFIRMED | Declared in `.mcp.json`, points at a non-existent file, **called nowhere** — vestigial | Wire it in Phase 4 (retrieval) — the cheapest path to real retrieval |
| 7.4 promotion | CONFIRMED | `promote.sh` is frequency-only; documented quality carve-outs (anti-pattern, local-path, internal/) **unimplemented** | Add the carve-outs + a quality gate (Phase 4) |
| 7.5 decay | CONFIRMED | `decay_days` parsed nowhere; globals are permanent | Add `prune-globals.sh` tied to retrieval recency (Phase 4) |
| 8.1 token cap | PARTIAL | Wall-clock watchdog **present** (`run-parallel-group.sh:184`); **no token/cost cap** | `--max-budget-usd` per worker + per-run cap (Phase 5) |
| 8.2 telemetry | CONFIRMED | Logs are build stdout only; no per-phase token/cost | Parse `--output-format json` `total_cost_usd`/`usage` → `run-summary.jsonl` (Phase 5) |
| 8.3 model tiers | CONFIRMED | `agents.builder_model`/`reviewer_models` config **never read**; only `CLAUDEHUT_WORKER_MODEL` env works | Read config (default sonnet) in dispatch (Phase 5) |

### A.5 — Already-correct / already-mitigated (do not "fix")

- **Artifact-derived state machine, harness-enforcement thesis, stub-commit, Bash-3.2 discipline, secret-scan, documentation honesty** — validated; keep.
- **`CLAUDEHUT_WORKER` guard in `stop.sh`** — genuinely prevents the learn-block from firing inside headless workers; real and working.
- **Path-B builder correctness fixes** (path canonicalization, `-B`, EXIT-trap cleanup, gitignore-aware merge, per-group gate) — verified by the real Gradle e2e (green 2/2). Keep.
- **`dispatch-prompt.sh` memory re-injection** — defensive even though CLAUDE.md *does* reach subagents; keep as belt-and-suspenders.

---

## Part B — Verified platform facts (and where the review is stale)

All quotes fetched 2026-05-29 from `code.claude.com/docs` / `anthropic.com/engineering`. Use these as the authority; flag `⚠︎ verify` items before acting.

**B.1 Nested subagents — UNSUPPORTED (confirms P0-2).** `sub-agents.md`: *"Subagents cannot spawn other subagents… use Skills or chain subagents from the main conversation."* `Agent` is filtered from a subagent's tool surface *"even when listed in the `tools` field"*; *"`Agent(agent_type)` has no effect in subagent definitions."* A fork *"cannot spawn further forks."* → Reviewers must be dispatched from the **orchestrator (top level)**.

**B.2 CLAUDE.md DOES reach custom subagents (REJECTS review §5.2).** `sub-agents.md`: custom subagents load *"every level of the memory hierarchy."* *"Explore and Plan are the only subagents that omit CLAUDE.md… There is no frontmatter field… to change which agents skip them."* The review's `tengu_slim_subagent_claudemd`/`omitClaudeMd` flags **do not appear** in current docs. → Do **not** strip CLAUDE.md claims; the memory hierarchy is a live channel for ClaudeHut's custom subagents.

**B.3 `skills:` preload — works for in-process Task subagents (nuances Path-B rationale, §5.1).** `sub-agents.md`: *"The full content of each listed skill is injected into the subagent's context at startup."* `--bare` *skips* skill discovery. So flatten-to-Task (P0-2) gives reviewers **both** skill preload and CLAUDE.md — a reason to prefer it over Path-B for the reviewer fleet. (Builder Path-B workers run `--agent` without `--bare`; their preload is still worth a startup self-check.)

**B.4 `context: fork`, `agent:`, `paths:` are STABLE (enables Phase 6; softens review §3.4 caveat).** `skills.md`: `context: fork` is *"functional"* (not experimental); `paths:` *"loads the skill automatically only when working with files matching the patterns"* (same glob as path rules). → Adopt `paths:` now; consider `context: fork + agent:` for phase dispatch.

**B.5 Stop-hook loop guard is BUILT-IN (simplifies §5.3 fix).** `hooks-guide.md`: *"Claude Code overrides a Stop hook after it blocks 8 times in a row without progress"*; parse `stop_hook_active` and exit 0 when true; cap via `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP`. → Use the platform field; still add ClaudeHut's own bounded escape for clean UX.

**B.6 Command hooks cannot call tools (confirms §5.5).** `hooks-guide.md`: *"Command hooks… cannot trigger `/` commands or tool calls."* PreToolUse can `deny`/`allow`/`ask` + `additionalContext` + `updatedInput`. → migration validation at write-time must be a **regex/script gate**, not an agent.

**B.7 Headless cost/observability primitives exist (enables Phase 5).** `cli-reference.md`/`headless.md`: `--max-budget-usd` (print mode), `--max-turns` (print mode), `--output-format json` → `{result, session_id, total_cost_usd, modelUsage}`. → Per-worker budget cap + per-phase token/cost telemetry are a few lines each.

**B.8 Agent SDK = the real "harness" foundation (Phase 7).** `agent-sdk/overview`: *"the same tools, agent loop, and context management that power Claude Code, programmable in Python and TypeScript"* — programmatic subagents (`agents:{}`), hooks as callbacks, `allowedTools`+`permissionMode`, resumable sessions, typed messages. Caveat (`agent-sdk/skills`): SKILL `allowed-tools` frontmatter **does not apply under SDK** — use the `allowedTools` option.

**B.9 Memory/retrieval evidence (grounds Phase 4).** *Effective context engineering*: **just-in-time retrieval** (lightweight identifiers, load at runtime) + **context rot** (recall degrades as tokens grow) + *"smallest possible set of high-signal tokens."* Official **memory MCP**: entities/relations/observations, `search_nodes`/`open_nodes`, JSONL. **Tree-Sitter codebase-memory MCP** (arxiv 2603.27277): structural graph (CALLS/IMPORTS/DEFINES…) at *"10× lower token cost and 2.1× fewer tool calls"* vs file-exploration. **Managed Agents memory stores**: scope at **write time**, `content_sha256` optimistic concurrency, *"many small focused files."*

**B.10 Eval evidence (grounds Phase 2).** *Demystifying evals*: **pass@k** / **pass^k**, transcript metrics (`n_total_tokens`, ttft/ttlt), three grader types (code-based / model-based / human); *"start small-scale testing right away."* Multi-agent post: *"~15× more tokens than chats"*; *"token usage by itself explains 80% of the variance"*; coding has *"fewer truly parallelizable tasks than research."*

**⚠︎ Unconfirmed — verify before citing:** the "model choice ≈ 5% of variance" figure (not in source — only "one of three factors"); a plugin named **`feature-dev`** (not in `discover-plugins`); the exact "tightly interdependent" coding quote (confirmed quote is "fewer truly parallelizable tasks"); harness-paper bandit specifics; **`anthropic.com/.../effective-context-engineering`** returned 404 (quotes via mirror) — re-verify.

---

## Part C — The reconciled vision: what "Harness agent that gets smarter" actually means

The user wants an **agentic harness** that auto-decides skills/rules and **gets smarter over time**. The review is right that ClaudeHut today is a **governed workflow**, not an agent, and that *"reinforcement learning"* oversells a static note-dump. The reconciliation — and the honest delivery of the user's goal — has three load-bearing moves, none of which require more agents or fine-tuning:

1. **Adaptive-depth routing = the "agent" move.** Anthropic's **Routing** pattern (verified, B.4/§3) is exactly "the system decides its own process." An orchestrator triage step classifies the request and chooses *which* artifacts/phases are required. The artifact-derived state machine still **gates** the chosen path (governance preserved) — but a one-line fix no longer pays the full 6-phase, ~15× cost. This is the single highest-leverage change and it moves ClaudeHut genuinely from "workflow" toward "agent" **without** losing determinism.

2. **JIT relevance retrieval + outcome signal = the honest "reinforcement."** Replace "dump 200 lines into every prompt" (today: an *empty* dump, P0-4) with: at dispatch, retrieve the **top-k learnings relevant to *this* task** (touched paths / package / stack / title), and rank them by a **usefulness prior** updated from outcomes (retrieved + Loop converged faster → ↑; retrieved + same anti-pattern reflagged → ↓; never-retrieved-in-decay → deprecate). *That* feedback loop is what makes the system measurably better at surfacing the right knowledge — and it is honest to call it **"Memory & Retrieval Reinforcement,"** not RL. Wire the **already-declared memory MCP** (cheapest) or a TF-IDF/Tree-Sitter index.

3. **Eval harness = the thing that makes "smarter" provable.** Without it (review §3.2/§9.C), every claim is unfalsifiable. A small benchmark of representative Spring tasks + transcript metrics (pass@1, retries, coverage, finding-counts, wall-clock, **token cost/task**) lets you A/B the router, the retrieval changes, and the model tiers instead of guessing. It is the substrate for 1 and 2 — so it comes **before** them.

**North star (review's closing, endorsed): the next version should be *smaller, measured, and adaptive* — not larger.** Meta-learning (propose new `rules/`/skills on repeated anti-patterns, human-approved, never auto-edit) is the compounding endgame: it hardens ClaudeHut's actual strength — the **enforcement** layer — turning "we keep seeing X" into "X is now structurally prevented."

---

## Part D — Sequenced roadmap (file-level, each with a proving test)

Effort: **S** ≤ ½ day · **M** ~1–2 days · **L** ~ a week+. Each item names the change and the test that proves it. Phases are ordered so each is a prerequisite for trusting the next.

### Phase 0 — Correctness: make the two headline subsystems actually work *(do first; nothing downstream is trustworthy until these land)*

> **Status: SHIPPED** on `feature/phase0-correctness` (385/385 tests; reviewer-shard write verified by a real `claude --agent` smoke; aggregate decision verified for high/critical/zero-shard/clean). **Residual (verify before merge):** 0.2 moves reviewer dispatch to the **main thread following SKILL.md prose** (run verifier → read summary → dispatch roster in one message → `aggregate-findings.sh`). That is LLM-interpreted multi-step orchestration — the *same class* as the Build-phase failure that forced Path B. It is verified at the **script/contract level** (aggregate, shard write, decision, stale-shard reset) and with a reviewer **in isolation**, but the **orchestrator actually driving the 3-step flow end-to-end is unverified**. Hardening options if it proves unreliable: a deterministic `run-verify-group.sh` wrapper (Path-B style) that the orchestrator calls once, instead of prose-driven multi-Task dispatch. The stale-shard reset (a Loop accumulates shards across iterations) is handled deterministically in `run-verify-parallel.sh`, which resets the shard dir before every verify iteration.

| # | Item | Files | Proving test | Effort |
|---|---|---|---|---|
| 0.1 | **Persist reviewer findings (P0-1).** Each reviewer writes its own shard before returning; aggregator merges shards; `subagent-stop.sh` → completion marker only | `agents/claudehut-reviewer-*.md` (add Write-shard contract), `skills/verify-review/scripts/aggregate-findings.sh` (merge `findings/<id>/reviewer-*.json`), `hooks/subagent-stop.sh` | Two concurrent reviewer shards → aggregate → assert both findings survive and `totals` reflect them (no lost update, non-zero totals) | M |
| 0.2 | **Flatten reviewer dispatch (P0-2).** Orchestrator dispatches reviewers in one message; verifier = gate-runner + aggregator; remove `Task` from verifier frontmatter | `agents/claudehut-verifier.md`, `skills/verify-review/SKILL.md`, `references/reviewer-dispatch.md` | L15 (below) passes; assert `verifier.md` `tools:` has no `Task`; assert SKILL dispatches reviewers at orchestrator level | M |
| 0.3 | **Standardize decision rule → `high==0` (P0-3, atomic w/ test).** | `aggregate-findings.sh:17`, `SKILL.md:88/96/111`, `tests/integration/reviewer-dispatch.sh:93-97` | Inject 1 High → assert `fail`; inject 0/0 → assert `pass` | S |
| 0.4 | **Regenerate `learnings-recent.md` (P0-4).** New `regenerate-recent.sh` (top-N JSONL→md), called at end of learner pipeline | `skills/learn/scripts/regenerate-recent.sh` (new), `skills/learn/SKILL.md:52`, `agents/claudehut-learner.md` (output contract) | After a learn run, assert `learnings-recent.md` contains the current `task_id` (not the stub) | S |
| 0.5 | **Close the test gaps that hid 0.1–0.3.** L15: add `Task`/`Agent` to blocked set + scan **frontmatter** `tools:` for dispatched subagents; L11: round-trip `aggregate-findings.sh` → `claudehut_findings_doc`; replace L6's hardcoded `findings.json` with a real aggregate call | `tests/run-all.sh` (L15 awk + list), `tests/integration/reviewer-dispatch.sh`, `tests/e2e/simulated/full-workflow.sh:418-439` | Suite is red on the *old* buggy code, green on the *fixed* code | M |
| 0.6 | **Findings-path prose cleanup (4.2).** | `run-verify-parallel.sh:4`, `SKILL.md:48`, `references/reviewer-dispatch.md:31`, `references/retry-escalation.md` | grep: no `state/tasks` in any verify-review doc | S |

### Phase 1 — Robustness, safety honesty, config wiring *(P1/P2; cheap, high trust-per-token)*

> **Status: SHIPPED** on `feature/phase1-robustness` (391/391 tests). Headline discovery: **`bin/claudehut-state` was entirely broken** — it sourced a nonexistent `scripts/hooks/lib/state.sh` and exited 1 on *every* call, silently killing every `claudehut-state {phase,retries,stack,config,docs}` agent-prose invocation. Fixed the lib path (bigger than 6.3's dot-prefix) + added an L2.1b "bin actually runs" test (it had only ever been `bash -n`'d). Done: 1.1 stop bounded-escape via `stop_hook_active` (platform field) + manual escape hatch; 1.2 `has_learnings` jq (pretty-JSON safe); 1.3 deterministic migration gate wired into pre-tool.sh (validates `tool_input.content` via temp file, deny on exit 1, allow on exit 2, no worker bypass) + migration-validator agent demoted to Loop-time review + stale refs fixed. **Verified the gate actually fires:** `hooks.json` PreToolUse `Write|Edit → pre-tool.sh`, so a `Write` of a new `**/db/migration/V*.sql` is validated. **Coverage caveat (honest):** the `Edit` path carries `old_string`/`new_string`, not `.content`, so an Edit to a migration validates the *pre-edit* on-disk content, i.e. **Edits that introduce unsafe DDL are not caught** — acceptable since migrations are append-only new files (Write) in practice; close it later via Edit-result reconstruction if needed; 1.4 `loop_max_retries` readable (`claudehut-state config`), verifier instructed to read it, AND a **deterministic backstop**: prompt-router surfaces "RETRY CAP REACHED" at `retries >= loop_max_retries` (read from config) so the loop can't silently run past the cap; 1.5 destructive block de-theatered (honest "speed-bump, not a sandbox" + golden updated); 1.6 bin lib-path + stack dot-prefix + help text; 1.7 **DONE** — `active-task.json` pointer written idempotently by SessionStart (atomic); on a task-id change it emits a **neutral** note (a pointer cannot distinguish a branch rename from a normal switch-to-new-task, so it states the fact and prescribes nothing — never falsely accuses of orphaning, the common multi-task flow); cleaned by `claudehut-finish` (verified end-to-end, incl. a discriminating switch test); 1.8 atomic `integrations.json` (same-dir tmp+mv); 1.9 confirmed no-op (docs already correctly state CLAUDE.md reaches custom subagents, per B.2).

**Bin-broken class fixed (surfaced while completing 1.7):** `bin/claudehut-finish` and `bin/claudehut-rollback` had the same wrong lib path as `claudehut-state` (sourced nonexistent `scripts/hooks/lib/state.sh` → exited 1 on every call), and called undefined `claudehut_active_task` / `claudehut_state_dir`. Fixed the lib path in all bins, added both functions to `state.sh` (also unblocks `discover`'s render + the scope-check script), made `claudehut-finish`'s archive `mv` tolerant of the artifact-derived layout (so it completes and reaches the pointer cleanup). Added a regression guard (no bin may source `scripts/hooks/lib/`) + a `claudehut-state`/`finish` runtime test (was only ever `bash -n`'d). `claudehut-worktree-create`/`-prune` were never broken (they just require an arg).

**Remaining honest residuals (design-inherent, not incomplete work):** (a) 1.4's retry threshold is enforced as a *deterministic surfacing*, not a hard block — blocking mid-loop is riskier than surfacing; a true hard gate belongs with the Phase-3 router. (b) `claudehut-finish` and `claudehut-rollback` still reference a legacy `state/tasks/<id>` archive model that the artifact-derived design doesn't populate. `finish`'s `mv` is now tolerant (finish verified end-to-end); `rollback`'s lib path + functions are fixed and it reaches its own logic without crashing, but its full legacy-model archive/restore path is **lib-fixed-but-unverified**. "What finish/rollback should archive" (likely the `.claudehut/specs|plans|findings` set) is a separate design question for a later phase.

| # | Item | Files | Proving test | Effort |
|---|---|---|---|---|
| 1.1 | **Bounded stop-escape (5.3)** using platform `stop_hook_active` + per-task counter → `systemMessage` after N | `hooks/stop.sh` | Learner that never writes → 3× `stop.sh` → 3rd returns `systemMessage`, not `block` | S |
| 1.2 | **`jq`-based `has_learnings` (6.4)** | `hooks/lib/state.sh:~110` | Pretty-printed entry → `has_learnings` returns found | S |
| 1.3 | **Deterministic migration gate (5.5)**: wire `validate-migration.sh` into `pre-tool.sh` for `**/db/migration/V*.sql`; demote/drop the orphan agent | `hooks/pre-tool.sh`, `agents/claudehut-migration-validator.md` | `CREATE INDEX` without `CONCURRENTLY` → write denied | S |
| 1.4 | **Wire `loop_max_retries` (6.1)** | `agents/claudehut-verifier.md`, verify dispatch | config=5 → 4th retry occurs before escalation | S |
| 1.5 | **De-theater destructive block (6.2)** + fix golden | `hooks/pre-tool.sh`, `tests/snapshot/golden/pre-tool-deny-rm-rf.json` | snapshot matches honest "speed-bump" text | S |
| 1.6 | **Fix `claudehut-state stack` (6.3)** | `bin/claudehut-state:43-45,81` | `stack web` returns the fixture value | S |
| 1.7 | **`active-task.json` pointer + collision/rename warning (6.5)** | task-start script, `claudehut_task_id` | two branches → same slug → init warns | M |
| 1.8 | **Atomic `integrations.json` (6.8)** | `hooks/session-start.sh` | two concurrent session-starts → valid JSON | S |
| 1.9 | **Correct the architecture doc (B.2/A.1)**: CLAUDE.md *does* reach custom subagents; dispatch-prompt redundancy is belt-and-suspenders, not the sole channel | `docs/ARCHITECTURE.md` (§10/§11), `skills/build/references/parallel-build-verification.md` | n/a (doc) | S |

### Phase 2 — Eval harness *(the substrate; before any strategic change)*

> **Status: SHIPPED** on `feature/phase2-eval-harness` + `feature/phase2-claudehut-row` (413 tests). Built `evals/`: a **deterministic scorer** (`score.sh` — CI-tested L17, 11 assertions: cost summing, findings, retries, wall extraction, **terminal_status/is_error**; no model calls), a **held-out oracle** model (grading tests live in `tasks/<t>/oracle/`, applied post-run against a copy the pipeline never saw — verified pass@1 discriminates fix vs no-fix and is held out of `repo/`), an **opt-in real-Claude runner** (`run.sh`, full-pipeline-capable, `--max-budget-usd` cost-cap, baseline + claudehut modes), and `compare.sh` (A/B).
>
> **Two real rows produced (the A/B is live, not asserted):**
>
> | mode | terminal_status | pass@1 | cost | wall |
> |------|-----------------|--------|------|------|
> | baseline | success | 1 | \$0.14 | 13s |
> | claudehut | **error_max_budget_usd** | 0\* | \$1.24 | 288s |
>
> \* **The claudehut row is a budget-KILL, not a capability verdict.** Killed by the \$1.00 cap mid-pipeline (16 turns) after producing a design doc + reuse-scan, **before reaching Build** — so `pass@1=0` grades an *unfinished tree* (the bug was never touched). Collapsing that into "claudehut fails the task" would overclaim. The **uncontaminated, real finding:** full 6-phase ceremony on a 1-line bug burned **~9× baseline's full-fix cost and never even reached the fix**. That is the empirical case for **Phase 3 (adaptive-depth routing)** — a trivial task must not pay the full pipeline tax. This run *earned a harness fix*: the scorer now records **`terminal_status` + `is_error`**, so a budget/turn-killed row **self-describes** instead of reading as "tried and got it wrong" (CI-locked in L17; `compare.sh` surfaces it first).
>
> **Headless dispatch seam (Phase-0 §2 residual) — PARTIALLY proven:** SessionStart fired (wrote `active-task.json` + `integrations.json`), the **brainstorm phase executed** (real design doc on disk), and the reuse-scan ran — so the early seam works headlessly. But the budget kill landed before Build, so the **full 6-phase orchestrator-prose dispatch end-to-end is still unproven** (needs a higher-budget run). **Cost caveat (verified):** scorer sums main-session `total_cost_usd` (orchestrator + in-process Task subagents) + Σ `.claudehut/logs/*.cost`, but Path-B build workers don't yet emit `.cost` (Phase-5 telemetry) → claudehut-mode cost is undercounted by build-worker spend; baseline mode is exact. **Remaining (opt-in / next):** a **higher-budget claudehut run (~\$3–4)** to learn whether the pipeline *completes and fixes* (and to finish exercising the dispatch seam), plus the full Spring suite (Kafka+DLT, Flyway, reactive handler, one large feature).

| # | Item | Files | Proving test | Effort |
|---|---|---|---|---|
| 2.1 | **Benchmark set**: 5 representative tasks (CRUD endpoint, Kafka consumer + DLT, Flyway migration, reactive handler, refactor) as fixtures | `evals/tasks/*` (new) | each fixture builds from a known baseline | M |
| 2.2 | **Runner + metrics**: run a task end-to-end, capture pass@1, retry count, JaCoCo coverage, reviewer findings by severity, wall-clock, **token cost/task** (`--output-format json` → `total_cost_usd`/`usage`) | `evals/run.sh`, `evals/score.sh` (new) | runner emits a metrics row per task to `evals/results/<ver>.jsonl` | L |
| 2.3 | **Baseline comparison**: same tasks on plain Claude Code + good `CLAUDE.md` + bundled `/code-review`,`/loop` — to falsify "the apparatus helps" | `evals/baseline/*` | a versioned A/B table | M |

### Phase 3 — Adaptive-depth routing *(the "workflow → agent" move)*

| # | Item | Files | Proving test | Effort |
|---|---|---|---|---|
| 3.1 | **Orchestrator triage** classifies intent → pipeline depth (Routing pattern). Artifact state machine still gates the chosen path | `agents/claudehut-orchestrator.md`, a `route` skill/script, `state.sh` (allow declared-subset paths) | trivial-fix intent → Build+Verify only (no Brainstorm/Spec/Plan/Learn); migration intent → full + mandatory DB review | L |
| 3.2 | **A/B via Phase 2**: measure cost/quality of routed vs full pipeline on the benchmark | `evals/` | routed path ≥ baseline quality at materially lower token cost on trivial/bugfix classes | M |

### Phase 4 — Memory & Retrieval Reinforcement *(the honest "gets smarter")*

| # | Item | Files | Proving test | Effort |
|---|---|---|---|---|
| 4.1 | **JIT relevance retrieval** (replaces head-N): query top-k learnings by touched paths/package/stack/title; inject ≤k hits | `skills/*/scripts/dispatch-prompt.sh`, `skills/learn/scripts/*` | 30 diverse learnings; a Mapper-only task → ≤k injected, all `mapstruct`-tagged | M |
| 4.2 | **Wire the declared memory MCP** (7.3): learner writes entities/observations (tags→entity types); dispatch retrieves via `search_nodes` on the task's files/tags | `agents/claudehut-learner.md` (+memory tools), `dispatch-prompt.sh` | after a learn run, `mcp-graph.json` has an entity; dispatch output references it. *(Alt: Tree-Sitter codebase-memory for structural traversal — B.9.)* | L |
| 4.3 | **Outcome-signal usefulness prior** (the "reinforcement"): per-learning `usefulness_hits`; increment when retrieved AND Loop converged / not reflagged; rank retrieval by it | `learnings.jsonl` schema, learner + verify hooks | a learning retrieved on a passing task → `usefulness_hits` ++ | M |
| 4.4 | **Quality-gated promotion (7.4) + decay (7.5)**: promote on `freq≥N AND not-tombstoned AND used-task-passed`; `prune-globals.sh` deprecates stale-by-recency | `skills/learn/scripts/promote.sh`, `prune-globals.sh` (new) | anti-pattern/local-path fixtures not promoted; 200-day entry → `deprecated:true` | M |
| 4.5 | **Meta-learning proposals**: on ≥K repeats of an anti-pattern, **propose** a `rules/`/skill addition for human approval (never auto-edit) | learner + a `proposals/` queue | 3 repeats → a proposal artifact surfaced, no rule auto-edited | M |
| 4.6 | **Honest rename** "Reinforcement Learning" → "Memory & Retrieval Reinforcement" across docs | docs | n/a | S |

### Phase 5 — Cost caps & telemetry

| # | Item | Files | Proving test | Effort |
|---|---|---|---|---|
| 5.1 | **Per-worker + per-run budget**: `--max-budget-usd`/`--max-turns` per `claude --print`; global run cap (skip/kill on breach) | `skills/build/scripts/run-parallel-group.sh`, `scaffold-stubs.sh` | budget=tiny → worker killed/skipped, surfaced | S |
| 5.2 | **Per-phase telemetry**: parse `--output-format json` → `run-summary.jsonl` `{phase,task,model,in_tok,out_tok,cost,ms}` | build + verify dispatch | a run produces numeric token/cost rows; feeds Phase 2 + 4.3 | S |
| 5.3 | **Wire model-tier config (8.3)** | `run-parallel-group.sh`, reviewer dispatch | config `builder_model=haiku` → `--model haiku` in the invocation | S |

### Phase 6 — Native primitives, modularization, DRY

| # | Item | Files | Proving test | Effort |
|---|---|---|---|---|
| 6.1 | **Adopt `paths:` activation (6.6) + relax 1% rule (6.7)** across skills; trim descriptions | all `skills/*/SKILL.md`, `using-claudehut`, agent personas | a Controller task does **not** invoke `kafka-consumer`; a `*NatsListener*` file auto-loads `nats` | M |
| 6.2 | **DRY guardrails (review §9.F)**: generate the `--append-system-prompt` fragment from the builder persona; assert equality in CI | build script + `tests/run-all.sh` | CI fails if fragment ≠ persona-derived | S |
| 6.3 | **Modularize (review §9.E)**: split into `claudehut-core` / `-spring` / `-messaging` / `-quality` on one marketplace | repo layout, `marketplace.json` | each sub-plugin validates + installs independently | L |
| 6.4 | **Consider `context: fork + agent:`** for phase dispatch where it beats bespoke `dispatch-prompt.sh` glue (now that it's stable, B.4) | phase skills | parity test vs current dispatch | M |

### Phase 7 — (Strategic / optional) Agent SDK orchestrator

| # | Item | Proving test | Effort |
|---|---|---|---|
| 7.1 | Re-platform the **orchestrator** on the Claude Agent SDK (programmatic loop, subagents, hooks, permissions, structured output, resumable sessions). Keep bash workers behind it initially. Caveat: SKILL `allowed-tools` doesn't apply under SDK — use `allowedTools`+`permissionMode` | the Phase 2 eval set shows ≥ parity at lower variance; control flow no longer depends on model cooperation | L+ |

---

## Part E — Sequencing rationale & north star

- **Why Phase 0 first:** the reviewer fleet and the learning channel — the two features that *define* ClaudeHut's value — **do not currently function end-to-end** (no-op gate; empty memory). Until they work, every other metric is measuring a hollow pipeline.
- **Why Eval (Phase 2) before strategy (3/4):** review §3.2 is correct — the apparatus is unfalsifiable without a baseline. The router (3) and retrieval (4) must be **A/B-proven**, not asserted. The eval harness is also reused by 4.3 (usefulness signal) and 5.2 (cost telemetry feeds it).
- **Why routing (3) before more memory plumbing:** routing slashes the common-case cost (no 15× tax on a one-line fix), which makes the heavier Phase-4 retrieval affordable and is the concrete "agent" move the user asked for.
- **Smaller, measured, adaptive:** every phase reduces blast radius (modularize), increases measurability (eval, telemetry), or adds adaptivity (routing, retrieval) — the opposite of "launch at maximum complexity."
- **Do NOT regress the wins:** artifact-state machine, harness enforcement, stub-commit, Bash-3.2 discipline, the Path-B builder fixes, and documentation honesty are the load-bearing strengths — extend, don't rewrite.

**Suggested first PR:** Phase 0.1 + 0.2 + 0.3 + 0.5 together (they're coupled: persisting findings, flattening dispatch, fixing the rule, and fixing the tests that enshrined the bugs) — this is the minimum change that makes the Loop gate *real*, and it is the prerequisite for trusting any eval.

---

## Part F — Open questions for reviewers + unconfirmed claims to verify

**For Codex / Claude Mythos:**

1. **Decision contract:** is `high == 0` the right gate for this domain, or is a documented "minor-warnings-allowed" policy (`high ≤ N`) intended? (P0-3 hinges on this.)
2. **Flatten vs Path-B reviewers:** given B.3 (Task subagents preload skills + load CLAUDE.md), is orchestrator-level Task dispatch (0.2) preferable to running reviewers as `claude --print &` like builders? Trade-off: in-process isolation/preload vs OS parallelism + uniformity with the builder path.
3. **Memory backend:** declared **memory MCP** (cheapest, graph) vs a **Tree-Sitter codebase-memory** MCP (structural, "10× lower token cost") vs a local TF-IDF/embedding index — which fits a Java/Spring shop best for Phase 4?
4. **Routing taxonomy:** is the intent→pipeline table (trivial/bugfix/small/large/migration) the right cut, and where should the classifier live (orchestrator prompt vs a deterministic pre-classifier)?
5. **Agent SDK (Phase 7):** worth the re-platform now, or defer until Phases 0–5 prove the design on the eval set?
6. **Modularization seams:** are `core / spring / messaging / quality` the right plugin boundaries?

**Unconfirmed platform/source claims to verify before building on them (`⚠︎`):**

- Review's **§5.2** (`tengu_slim_subagent_claudemd` / subagents-lose-CLAUDE.md): **contradicted** by current `sub-agents.md` (B.2) **and by a firsthand live probe** (an Agent-tool subagent read a CLAUDE.md-only sentinel). Treat as resolved for the current runtime; this does **not** disprove #40459 at the older version it cited — re-verify before targeting an older Claude Code release.
- "**model choice ≈ 5% of variance**" — not in the primary source; don't cite the number.
- **`feature-dev`** official plugin — not found in `discover-plugins`; `pr-review-toolkit`, `security-guidance`, `commit-commands`, `agent-sdk-dev`, `plugin-dev` are confirmed.
- **`context: fork` reliability** — current docs say *functional*; the review cited flakiness issues (#49559/#17283). Pilot behind the eval before broad adoption (Phase 6.4).
- **agent-teams `skills:` preload** — `agent-teams.md` not fetched; unconfirmed. Irrelevant unless agent-teams is adopted.
- **`anthropic.com/.../effective-context-engineering`** returned 404 at fetch time — re-verify quotes against the original when reachable.
- Specific **bandit weight-update rules** (4.3) are design synthesis, not a cited algorithm — implement as design, measure via Phase 2.

---

*Generated 2026-05-29. Inputs: `docs/REVIEW_ARCHITECTURE.md` (external review) + a code re-audit (file:line verdicts) + current-doc research (fetch-and-quote). This plan supersedes the review wherever Part A/B marks a divergence; otherwise it operationalizes the review's recommendations.*
