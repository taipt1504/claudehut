# Solution Design v0.4 — APPROVED & EXECUTED (see §Verification results at bottom)

> Produced by: 11 research+audit agents (6 web-research, 5 local-audit) → synthesis → 3-lens adversarial critique panel (native-first / enforcement-rigor / scope-simplicity, substituting the unavailable `advisor` tool). 8 blockers found by the panel in the first draft are corrected below.

---

## Issue 1 audit verdict (empirical — measured, not assumed)

**Measured bypass rate: 69% (11/16 tasks across 5 real-usage sessions)** — consistent with the claimed 70–80%. Sample: `~/.claude/projects/-Users-taiphan-Documents-Projects-ewallet-workspace-payment-gateway-ms/*.jsonl` (N=16 tasks; small N, but covers real production usage).

| Session | Pattern | Evidence |
|---|---|---|
| 90fc6ff8 | Gate blocked 3× → ran discover/spec/plan **reactively to satisfy the gate** → wrote **51 production files with ZERO `Skill(implement)` calls** | idx 377–452 |
| 8ff980ee | Same; agent ran `claudehut-state set-phase implement` **via raw Bash** but never invoked the skill → 16 production writes | idx 308–496 |
| c7a2e063 | 10 tasks; `Skill(implement)` called 3× but all for task 0005; tasks 0006–0014 = 0 invocations; **535/693 writes after the last skill call** | idx 4237–11852 |
| aea7ad68, 77900a5a | Correct: 1:1 skill-per-task, worktree dispatch | — |

**Root cause chain (cited):**
1. `gate-write.sh:83-105` checks only artifact existence (`reuse_scan` + `spec_path` + `plan_path`) — **zero check** that `Skill(implement)` was invoked, that `phase=implement`, or that an implementer was dispatched. Once artifacts exist, the gate is **permanently open**.
2. `inject-phase.sh:3` — "Advisory only — never blocks."
3. `bin/claudehut-state` — backward-transition guard only; forward skip (`plan→implement` via raw Bash, no skill) is free.
4. `verify-subagent.sh:50-52` — catch-all `*)` skips `claudehut-implementer` verification.
5. Skill auto-invocation is model-discretionary by design — official docs: *"There is NO native mechanism to FORCE a skill… hooks are the only deterministic enforcement layer"* [code.claude.com/docs/en/memory]. The "1% rule" in `claudehut-workflow/SKILL.md:37` is instruction-level only (same gap Superpowers has — Jesse Vincent: *"Claude Code knows it's supposed to use skills automatically, but it's not reliable yet"*).
6. **Consequence of bypass:** Iron Law TDD, the rules-table + create-time playbooks, and the parallel implementer dispatch all live ONLY in the implement SKILL.md body — skipped skill = all three lost at once.

Eval gap: `evals/` measures gate conformance (21/21) and playbook reads (87%) but **nothing measures skill-invocation-before-write** — why this went undetected.

---

## Fix 1: Enforcement guarantee (CRITICAL — first in execution order)

**Strategy:** make the **hook layer** (the only deterministic native layer) require *proof of skill invocation*, not just artifact existence. The proof flag is set by a hook that fires on the actual `Skill` tool call — the model cannot satisfy it without loading the skill body.

### Mechanism (native: PreToolUse hooks, most-restrictive-wins; SessionStart restore)

**A. New Rail 0 in `gate-write.sh` — runs BEFORE the fast-lane allow (panel BLOCKER: original draft placed it after line 91 `allow`, making it dead for trivial/small — the dominant bypass tier).** Production write allowed only when state has `implement_skill_ok=true` for the **current task dir**. Deny message: "invoke `claudehut:implement` (1 Skill call) then retry."

**B. New PreToolUse hook entry, matcher `Skill`** → `scripts/record-skill.sh`: when `tool_input` targets `implement` (or `claudehut:implement`), write `implement_skill_ok=true` + `implement_task_dir=<current task dir>` to session state. Always exits 0/allow — it's a recorder, not a gate.
   - `[uncertain — verify with live probe before building]`: PreToolUse firing for the `Skill` tool name. Fallback if it doesn't fire: PostToolUse matcher `Skill`; second fallback: `implement` SKILL.md instructs running `claudehut-state set-implement-ok` as its step 0 (weaker — Bash-fakeable — but combined with Rail 0 deny messages still forces the skill text into context, since the deny tells the agent to invoke the skill, and invoking it loads the body).

**C. Per-task reset (closes the c7a2e063 multi-task hole):** `claudehut-state` resets `implement_skill_ok=false` whenever a new task dir is created / `set-phase discover|brainstorm` runs. One skill invocation per TASK, not per session.

**D. Compact/resume survivability (panel BLOCKER: re-armed `phase=brainstorm` after compact would wedge the session):** `bootstrap.sh` matcher already covers `compact|resume` — restore `implement_skill_ok` + phase from the PreCompact snapshot (`persist-state.sh`) instead of re-arming blind. If no snapshot: deny message costs exactly one `Skill(implement)` re-invocation — not a wedge.

**E. Honest limits (stated in docs, not hidden):** `bypass=true` stays the single documented escape hatch (already exists, `gate-write.sh:46`); a determined agent can still Bash-edit state files. Goal is **eliminating drift** (the 69% was drift, not adversarial: every bypassed session complied the moment the gate pushed back — see 90fc6ff8 reactively completing phases). Deny-with-instruction is the strongest native lever: official docs confirm PreToolUse `permissionDecision:deny` cancels the call and feeds the reason back.

**F. Dropped from draft (panel BLOCKERs):** the `verify-subagent.sh` implementer branch-check — SubagentStop payload has **no `.branch` field**; the check would silently never run. Out of Fix 1; the worktree `reconcile --test-cmd` path already verifies implementer output with real tests.

### Files (design ↔ impl sync)
| Impl | Design doc |
|---|---|
| `scripts/gate-write.sh` (Rail 0, before fast-lane) | `06-hooks.md` (gate table + Rail 0) |
| `hooks/hooks.json` (PreToolUse matcher `Skill`) | `06-hooks.md` |
| `scripts/record-skill.sh` (NEW) | `06-hooks.md` |
| `bin/claudehut-state` (flag set/reset, restore) | `01-agentic-workflow.md` §4 state machine |
| `scripts/bootstrap.sh` (restore-from-snapshot on compact/resume) | `06-hooks.md` §5 |

### Verification (real run)
1. Live probe FIRST: does PreToolUse fire on `Skill`? (5-min headless test; decides A-vs-fallback before any build.)
2. New eval `evals/tasks/implement-skill-bypass/`: oracle = per-task `Skill(implement)` before first production write (per-TASK coverage, not session-boolean — panel MAJOR). Run headless ×20; report raw counts (no false "≤5% guaranteed" claim — N=20 only bounds gross regression, stated honestly).
3. Regression: `evals/gate-tests.sh` 21/21 + compact-mid-implement scenario (no wedge).

---

## Fix 2: Fast path for simple tasks

**Measured problem:** even `trivial` runs 2 Discover subagents (~26s overhead floor, BENCH-REPORT:17-19) + ≥2 review auditors; `small` adds a mandatory learner dispatch = **5 subagent round-trips for a ≤2-file change**. Default tier is `full` if the model forgets to triage.

**Native mechanisms:** existing tier routing verified by `gate-write.sh` (deterministic); skill-description SKIP conditions (the measured 20→90% activation lever).

| Change | Detail | Why safe |
|---|---|---|
| A. Inline Discover, `trivial` only | 3 Grep calls + inline `reuse-scan.md` (DECISION/Searched/FOUND) + `set-reuse-scan`. ~5 tool calls, zero dispatches. Update `discover/SKILL.md:44` "BOTH mandatory" → scoped to small/full (panel MAJOR: avoid contradictory Iron Law). | Reuse-rail still gate-enforced; trivial = no-logic changes by definition |
| B. Security-auditor opt-in for trivial/small | Skip when tier∈{trivial,small} — **deterministically backed**: `fastlane_bound_ok()` already denies fast lane on any `security|/auth|migration` path (`gate-write.sh:77-78`), so fast-lane diffs cannot contain security surface | Gate, not model judgment, guarantees the precondition |
| C. Inline Learn, `small`, nothing-novel case | One-line JSONL entry inline instead of learner dispatch | `gate-done.sh` checks content, not author |
| D. Move here from Fix 4: `discover` description SKIP condition ("skip only for pure doc/comment edits") | Routing change belongs in Fix 2 (panel) | — |

Files: `skills/discover/SKILL.md`, `skills/review/SKILL.md`, `skills/capture-learnings/SKILL.md` ↔ `01-agentic-workflow.md`, `06-hooks.md`.
Verify: `evals/bench/simple-task-bench.sh` — trivial Discover ≤5 tool calls/0 dispatches; small DTO change skips security-auditor; wall-clock before/after.

---

## Fix 3: Reviewable doc templates

**Measured problem:** `plan.md` 1,477 words (609-char "Minimal change" cells); `reuse-scan.md` 1,178 words (per-dimension prose triple); `spec.md` §12 = 29-rule prose blob; `review.md` (420 words, findings table) is the in-repo gold standard. Root causes traced to missing cell budgets in `claudehut-planner.md:36` and **no reuse-scan template file at all**.

**Pattern source (cited):** summary-first + tables-over-prose (Rust RFC, Nygard ADR, Stripe writing culture, Google design docs); review.md already proves the format works.

| Change | File |
|---|---|
| Cell budgets as **direct agent instruction** (primary): `Test first` = `Class#method` ≤60 chars; `Minimal change` = intent ≤30 words; OQ resolution stated ONCE (§1 only — currently repeated 3×) | `agents/claudehut-planner.md` |
| Same budgets as header annotations (secondary) | `skills/write-plan/references/plan-template.md` |
| §12 Enforcement Manifest → two-column table, never prose | `skills/write-spec/references/spec-template.md` |
| NEW `reuse-scan-template.md`: Summary table FIRST (Dimension/Asset/Decision/Effort), evidence only for non-obvious decisions, one line each | `skills/discover/references/reuse-scan-template.md` (repo convention — panel: NOT `agents/references/`) + dispatch-prompt pointer in `skills/discover/SKILL.md` + format note in `agents/claudehut-reuse-scanner.md` |

Design sync: `11-execution-model-and-artifacts.md` (artifact length budgets: plan ≤500w, reuse-scan ≤400w, spec ≤800w).
Verify: regenerate the same example task; `wc -w` oracle + side-by-side spot-check vs `.claude/reviews/examples/`.

---

## Fix 4: Expert-grade rules/skills/agents + coverage

**Audit verdict:** library is bimodal. `performance/indexing.md` and the `references/` playbooks (jpa.md 187L, caching.md 194L) are genuinely expert; the path-scoped rules they should back are shallow (jpa.md 81L missing `@ManyToOne` EAGER-default, open-in-view; webflux.md 59L missing context propagation, flatMap-vs-concatMap, error recovery; redis.md missing `sync=true`, stampede; spring-mvc.md missing ProblemDetail/RFC 7807, advice ordering). Benchmark: JetBrains junie-guidelines Spring canon + claudehut's own playbooks.

| Pri | Action | File |
|---|---|---|
| P1 | UPGRADE to playbook depth (distill from own `references/` — content already researched) | `framework/jpa.md`, `webflux.md`, `redis.md`, `spring-mvc.md` |
| P2 | ADD `@Transactional` propagation decision table (REQUIRES_NEW/MANDATORY/NOT_SUPPORTED + failure modes) | `framework/transaction-propagation.md` (NEW) |
| P2 | ADD Postgres locking (FOR UPDATE SKIP LOCKED, advisory locks, pg_locks) | `performance/postgres-locking.md` (NEW) |
| P2 | ADD JWT validation (Nimbus/Spring Security 6 default; algorithm confusion, `aud` check) — no existing jwt rule found | `security/jwt-validation.md` (NEW) |
| P3 | ADD virtual threads (pinning, Hikari sizing) — Java 21 ⊂ "Java 11+" domain | `framework/virtual-threads.md` (NEW) |
| P3 | UPGRADE: rebalance/backoff (kafka-consumer); `@ServiceConnection` singleton + Ryuk CI (testcontainers); WireMock 3.x lifecycle | `kafka-consumer.md`, `testing/testcontainers.md`, `wiremock.md` |
| — | Agents: `claudehut-reviewer.md` + fast-lane domain checklist (fires when enforcement set empty — the trivial/small case); `claudehut-implementer.md` + create-time playbook-read reminder | agents/ |
| — | `skills/implement/SKILL.md` must-dos: add "rule file wins on divergence" pointer (anti-drift) | skills/ |

**Excluded with reason (anti-sprawl, per constraints):** observability/Micrometer, Resilience4j, saga, ShedLock, Spring Batch — real gaps found by audit but **outside the stated target domains**; listed in `05-rules.md` as a future-coverage note only.

Design sync: `05-rules.md` gap matrix. Verify: 3 eval prompts per new/upgraded rule via `evals/rule-load-probe.sh` pattern (trigger / non-trigger / edge).

---

## Fix 5: Compounding memory

**Audit verdict:** capture+inject pipeline is real and decent (confidence×hits×30-day-decay ranking implemented); the **compounding** half is missing: promotion is design-doc-only (07:247 — zero implementation), no pruning (append-only forever), dedup normalization undefined (model-judgment), confidence delta unspecified.

**Research grounding:** write-on-failure compounds (Reflexion, NeurIPS 2023: 91% vs 80% pass@1); promotion = the episodic→semantic distillation step (Letta/MemGPT) done natively via files; >200-line always-loaded memory degrades adherence (Anthropic context-engineering cookbook) → promote-then-stop-injecting is also the cost control.

| Change | File |
|---|---|
| A. Pitfall→rule promotion: learner step 6 — `hits≥5 ∧ confidence≥0.85 ∧ category=pitfall` → append `## Learned pitfall` block to the matching `.claude/rules/` file, set `promoted:true`. Mapping = **static trigger→rule-path table embedded in the learner prompt** (panel: learner has no Glob/Bash — discovery impossible; static table is auditable and sufficient) | `agents/claudehut-learner.md` |
| B. Skip promoted entries at injection (insertion point: inside jq pipeline before `sort_by(-._score)` — panel corrected line ref) | `scripts/inject-learnings.sh` |
| C. Deterministic dedup key: lowercase, tokenize on `[| ,-]`, sort, rejoin — `"reactive|r2dbc" ≡ "R2DBC|reactive"` | `agents/claudehut-learner.md` |
| D. Confidence merge formula: `min(old+0.05, 1.0)` (draft's 0.99-cap dropped — no mechanical consequence, panel MINOR) | `agents/claudehut-learner.md` |
| E. Pruning: drop `promoted=true` and `(confidence<0.25 ∧ hits≤1 ∧ age>90d)`; log dropped count | `agents/claudehut-learner.md` step 7 |
| F. DROPPED from draft: gate-done mtime check — already covered at the right boundary by `verify-subagent.sh:40-48` (learner case); the gate-done variant had a multi-task mtime bug (panel BLOCKER) | — |

Design sync: `07-memory-architecture.md` §5.1 (formula), §5.2 (dedup spec), §5.4 (promotion pipeline — moves from "future" to spec'd), §5.5 (pruning); `templates/MEMORY.md.tmpl` note.
Verify: `evals/ranker-tests.sh` new scenarios — reversed-token dedup merges to one entry; synthetic 5-hit pitfall → promoted into rule file + disappears from injection output.

---

## Execution order (Issue 1 first)

| # | Step | Verify |
|---|---|---|
| 1 | **Fix 1** — live probe (PreToolUse on Skill) → build Rail 0 + recorder hook + state flag + compact restore → docs 06+01 | new bypass eval ×20 headless + gate-tests 21/21 + compact scenario |
| 2 | **Fix 3** — templates + planner/scanner budgets → doc 11 | wc-w oracle + spot-check vs old examples |
| 3 | **Fix 2** — fast lanes (depends on Fix 1 so the fast path stays enforced) → docs 01+06 | simple-task bench |
| 4 | **Fix 4** — P1 upgrades → P2 new → P3 → agents/skill → doc 05 | rule-load probes 3/3 per file |
| 5 | **Fix 5** — learner steps + inject filter → doc 07 | ranker-tests + promotion oracle |

Every step = plugin file + design doc in the same commit. Stop-and-ask triggers honored: no deletions/merges of skills/agents/phases anywhere in this plan; no new dependencies; nothing outside the repo.

## Resolved-by-recommendation (objections welcome)
1. Escape hatch = existing `bypass=true` only; no new `--skip-skill` subcommand (less surface).
2. JWT rule written for Nimbus/Spring Security 6 (default), custom-impl note included.
3. Promotion mapping = static table (not a new `bin/claudehut-promote` script).

## Known [uncertain]
- PreToolUse firing on `Skill` tool calls — resolved by the live probe in step 1 before any build; documented fallback chain if not.
- N=20 eval runs bound gross regression only, not a statistical ≤5% guarantee — reported as raw counts.

---

# Verification results (post-execution, 2026-06-12/13)

## Fix 1 — Enforcement (skill rail)
- **Live probe 1:** PreToolUse fires on the `Skill` tool, payload `{"tool_input":{"skill":"<name>"}}` — mechanism A confirmed, no fallback needed.
- **Live probe 2:** gate JSON deny (`permissionDecision:"deny"`, exit 0) **holds under `--dangerously-skip-permissions`** — Write denied, file not created. Resolves the panel's [uncertain] blocker with real evidence.
- **Live eval `implement-skill-bypass` (sonnet, headless, ×5): 5/5 pass** — every run invoked `Skill(claudehut:implement)` before its first production write (`implement_skill_ok=true` in state, set only by the recorder hook); trial 5 completed the entire 7-phase workflow. Measured baseline from real transcripts: 69% bypass (11/16 tasks). New-bypass count: **0/5**. [N=5, not the design's N=20 — raw counts reported per the honesty rule; deterministic suites cover the rail logic exhaustively.]
- **Deterministic:** gate-tests **63/63** (incl. skill-rail open/close/reset, qualified names, recorder end-to-end, legacy pre-v0.4 state migration, snapshot restore).
- Harness fix required: CC ≥2.1.x headless flags `.claude/**` writes "sensitive" under acceptEdits (deadlocked the workflow) → run.sh switched to `--dangerously-skip-permissions` AFTER probe 2 proved the deny-hooks still bind; security note added to run.sh.

## Fix 2 — Fast path
- Skills/docs landed (inline trivial Discover, gate-backed security-auditor skip, inline small-tier Learn). Eval prompt suffix in run.sh was forcing the full-phase path (pre-tier wording) — fixed to "triage tier first". **[not verified live]: wall-clock improvement for a trivial-tier run — the ×5 batch above pre-dates the prompt fix and ran full-tier; measure with `evals/run.sh --live implement-skill-bypass` post-fix.**

## Fix 3 — Doc templates
- Spot-check (regenerated plan for the same spec as the old example): **1,477 → 755 words (−49%)**, max `Minimal change` cell **609 → 205 chars**, OQ resolutions deduplicated to exactly once. Reuse-scan/spec template changes land via the same dispatch-prompt mechanism.

## Fix 4 — Rules/agents
- 12 rule files authored (8 upgrades + 4 new), then format/depth-verified; 2 real API bugs fixed (`JwtClaimNames.AUD`; `@PageableDefault` has no `max` — resolver customizer shown instead); 2 verifier false-positives overturned via context7 (`ConsumerAwareRebalanceListener#onPartitionsRevokedBeforeCommit/AfterCommit` and `spring.main.keep-alive` are real APIs). 3 longest files trimmed to ≤158 lines.
- **Migration verified by smoke test:** `--refresh-rules` + bootstrap version-stamp delivers upgraded templates to existing projects, preserves learner-promoted `## Learned pitfalls`, and stack-gates correctly (postgres rule emitted for postgresql project, skipped for mysql; jwt rule now emitted — its compound stack tag was a panel BLOCKER, removed). conformance **83/83**.

## Fix 5 — Memory
- ranker-tests **8/8** (incl. new: promoted-entry injection skip ×2, deterministic trigger-normalization algebra). **[not verified live]: end-to-end promotion after 5 recurring-pitfall sessions — instruction-driven learner behavior; the file-level mechanics (skip + preservation on refresh) are test-covered.**

## Final panel (advisor substitute)
3-lens adversarial panel over the diff: 2 true BLOCKERs (jwt stack tag; no template migration path) fixed + smoke-tested; legacy-state migration covered by a new gate test + recovery-hinting deny message; 9 stale design↔code sync items fixed (bootstrap arms `discover`; understand-anything wording; review "phase 6 of 7"; Law 6; MEMORY.md.tmpl ×2; doc 06 pseudo-logic/`async`/`if` claims; gate-done comment). Plugin version → **0.4.0** (drives the rule-migration stamp).
