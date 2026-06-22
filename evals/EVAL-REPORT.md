# ClaudeHut — Evaluation Report (interim)

Measured against the documented objectives (00-overview goals + 6 pillars + 01 workflow contract).
Every row is a real measurement, `[not run]`, or `[uncertain]`. Tiers: **T0** deterministic gate unit-tests ·
**T1** static/structural + ranker + runtime-load · **T2** live agentic (multi-trial).

## Scorecard (interim — T0+T1 complete, T2 blocked)

| Objective | Criterion | Result | Method · confidence |
|---|---|---|---|
| **P1** workflow enforced | write-gate + completion-gate + subagent-verify decision matrix | **PASS 17/17** | T0 `gate-tests.sh` — deterministic |
| **P2** coherent roster, one-skill-per-phase, phase chain | 8 skills + 11 agents, frontmatter, REQUIRED-NEXT chain, rule path-scoping, clean manifest | **PASS 47/47** | T1 `conformance.sh` — deterministic (structural) |
| **P5** cross-session learning (read path) | `inject-learnings.sh`: relevance filter > recency, recency orders ties, `--top` caps | **PASS 5/5** | T1 `ranker-tests.sh` — deterministic |
| **P6** native integration — manifest VALID & plugin LOADS | `claude -p --plugin-dir` `system/init`: claudehut in `plugins[]`, `plugin_errors=[]`, SessionStart hooks fire | **FAIL → PASS** (after approved fix) | T1 load probe — deterministic |
| P1 workflow non-optional (live reliability) | does the workflow start + complete every trial? | start 6/8; **complete 4/8**; per-task completion 2/2, 0/2, 1/2 (**n=2 per config — indicative, not enough for pass^k**) | T2 — 8 live runs · behavioral |
| P4 reuse-before-build (live) | `reuse-exists` adopts `TextUtils`, no duplicate | **reuse PASS — no duplicate slugify in 2/2 (verified)**; the one oracle "fail" was #5 (reuse-scan written non-canonically → oracle grep missed it), **not** a reuse miss | T2 · behavioral, verified |
| P5 learnings persisted (live) | learnings written to canonical `.claude/claudehut/learnings.jsonl` | **4/6 canonical** (else wrong path/file) | T2 · behavioral |
| P3 project-adaptive memory (live) | init generates project plane; rules stack-gated | **FAIL → FIXED** — script-backed init + deterministic SessionStart fallback writes the plane (init-tests 36/36) | T2 + deterministic |
| Cost/latency (characteristic) | $/run vs plain-Claude baseline ($0.142) | mean **~$2.8/run (~18×)**, 4/7 hit $3 cap | T2 benchmark — not a scored objective |
| **[uncertain]** | 1%-rule enforcement-set *completeness*; "reasons well"; worktree `${CLAUDE_PROJECT_DIR}` remap; `session_id` byte-identity | not measurably testable | — |

## #1 finding — P6 runtime load FAILED (now FIXED, approved) — manifest over-declared default locations

**Evidence (measured, load probe `claude -p --plugin-dir <repo> --output-format stream-json`):** the as-built
manifest failed to load in two ways, surfaced one at a time:
```
1) Validation errors: agents: Invalid input
2) Hook load failed: Duplicate hooks file detected: ./hooks/hooks.json ... the standard hooks/hooks.json
   is loaded automatically, so manifest.hooks should only reference additional hook files.
```
Other installed plugins (context7, caveman, understand-anything, claude-hud) loaded fine; **claudehut did not.**

**Root cause (one bug class):** the manifest **re-declared default component locations** —
`"agents": "./agents"`, `"hooks": "./hooks/hooks.json"` (and redundantly `"skills": "./skills"`). The runtime
`--plugin-dir` schema rejects a string for `agents` and errors on a `hooks` ref that duplicates the
auto-loaded `hooks/hooks.json`. The standard `agents/`, `skills/`, `hooks/hooks.json` are **auto-discovered**;
the manifest should only name *non-default* locations. `claude plugin validate .` did **not** catch this (it
validates `marketplace.json`, not the runtime manifest schema) — static checks passed while runtime load failed.
This also invalidated the prior build's "loads, exit 0" claim, which checked only the exit code, not `plugin_errors`.

**Fix applied (with approval) + re-validated:** reduced `.claude-plugin/plugin.json` to **pure metadata**
(removed `agents`, `skills`, `hooks` keys — all auto-discovered). Re-probe: `claudehut_loaded:1`,
`plugin_errors:[]`, and SessionStart hooks fire (`hook_started SessionStart:startup` + responses observed).
`conformance.sh` extended with a regression check that fails if the manifest re-declares `agents`/`hooks`.
Design doc `09-plugin-structure.md` §2 synced to the corrected manifest.

**Lesson for the harness:** `claude plugin validate` is insufficient for P6; the authoritative load check is
`claude -p --output-format stream-json` → inspect `system/init.plugin_errors`. Now part of the eval.

## Live tier (T2) — observed behavior (headless `claude --print`, transcript-verified)

Two characterizing runs on `clean-first-run`, plus a 6-run multi-trial matrix. **Matrix results** (workflow
progress from the authoritative state file; `canon` = artifacts present in canonical `.claude/claudehut/`):

| task | init? | pass@1 | wf phase | wf completed | canon r/s/p/l | cost | terminal |
|---|---|---|---|---|---|---|---|
| reuse-exists | yes | 1 | learn | **yes** | T/F/F/T | $2.95 | success |
| reuse-exists | yes | **0** | learn | yes | F/F/F/T | $3.37 | max_budget |
| clean-first-run | yes | 1 | learn | no (capped in review) | T/F/F/T | $3.77 | max_budget |
| clean-first-run | yes | 1 | **none** (workflow skipped) | no | F/F/F/F | $1.46 | success |
| shortcut-attempt | no | 1 | implement | no (capped) | T/T/T/F | $3.01 | max_budget |
| shortcut-attempt | no | 1 | learn | **yes** | F/T/T/T | $2.53 | success |

Variance is high: same task+config gives different trajectories (e.g. clean-first-run completed once, skipped
the workflow entirely once). **spec/plan never landed in the canonical store (0/6).** 4/7 runs (incl. diagnostic)
hit the budget cap. `shortcut-attempt` (prompted to "skip the process") nonetheless ran the workflow both
trials — the orchestrator instruction resisted the shortcut.

| Run | Config | pass@1 | workflow (from state file) | terminal | cost | notes |
|---|---|---|---|---|---|---|
| Smoke | no init, single prompt | 1 | **not started** (no state) | is_error, ~300s (likely timeout-truncated) | $0.75 | agent coded directly; gate fail-open (no state) |
| Diagnostic | init-first + "drive workflow" prompt | 1 (code built) | **COMPLETED**: `phase:learn, reuse_scan:true, spec_path, plan_path, review:pass` | error_max_budget_usd ($2 cap) | $2.00 / 54 turns | workflow drove correctly (1 `brainstorm` Skill → 3 `Agent`: explorer→reuse-scanner→brainstormer → `write-spec`; gate denials fired in the right order). Artifacts written to NON-canonical paths. |

### Finding #2 — P1/P4 enforcement is opt-in (gate fails open until the agent itself starts the workflow) — **HIGH**
Code fact: `bootstrap.sh` (SessionStart) injects the orchestrator but **writes no state file**; `gate-write.sh`
does `[ -f "$STATE" ] || allow`. So at turn 1 there is no state → the write gate **allows production writes**.
The state file only appears once a skill runs `claudehut-state set-phase` — i.e. once the agent *voluntarily*
starts the workflow. Corroborated empirically: the no-init smoke never started the workflow and wrote code with
no gate block; the init-first diagnostic — where the agent *did* run `set-phase brainstorm` first — then saw the
gate fire correctly. **This falsifies the documented universal guarantee** (01 §10: "the agent literally cannot
create a new file until it checked for reuse, specified, and produced a plan"). Holds regardless of headless vs
interactive — it is a property of the hook wiring. (Smoke's 300s/`is_error` looks timeout-truncated, so it
corroborates rather than solely proves; the code fact is the basis.)

### Finding #5 — workflow writes artifacts to NON-canonical paths → P3/P5 broken — **HIGH**
The diagnostic's state reached `review:pass`, but the artifacts did not land in the design's canonical
`.claude/claudehut/` store: spec → `specs/sum-service.md`, plan → `plans/sum-service.md` (bare, cwd-relative);
learnings → `.claudehut/memory.jsonl` (wrong dir *and* wrong filename vs `.claude/claudehut/learnings.jsonl`);
the reuse-scan artifact was not durably present in any expected location. The agent also improvised an entire
`.claudehut/{index.json,rules-src-*.md}` tree. Consequences: (a) `CLAUDE.md` `@import .claude/claudehut/MEMORY.md`
loads nothing; (b) P5 cross-session learning is dead — next session's `inject-learnings.sh` reads
`.claude/claudehut/learnings.jsonl`, which is empty; (c) committed-memory team sharing breaks. Root cause: skill
bodies under-specify the absolute artifact root and `init` never establishes `.claude/claudehut/`, so the agent
picks its own paths.

### Finding #6 — the write gate trusts STATE FLAGS, not artifact existence/location — **MEDIUM**
`gate-write.sh` opens once `reuse_scan=true` AND `spec_path`/`plan_path` are non-empty in state — it never checks
that those paths exist or are under `.claude/claudehut/`. So a `set-reuse-scan --artifact .claudehut/…`
(non-canonical, or a path that isn't durably written) still opens the gate. The "proof of work" is a flag a
skill sets, not the artifact itself. (`verify-subagent.sh` does check a reuse-scan file on SubagentStop, but did
not block this run.) Adjacent: `clean-first-run #1` reached `phase:learn` with `review≠pass` — nothing enforces
the state-machine *transition order*; `claudehut-state` sets whatever phase it is told.

### Finding #3 (revised) — workflow is expensive; init does not generate the project plane — **MEDIUM**
The full workflow *completes* but cost **$2.00 / 54 turns** for a trivial task and tripped the budget cap. Much
of the turn-spend was the agent improvising a bootstrap because **`claudehut-init` emitted a JSON stack analysis
to stdout and generated NO project-plane files** (`init.json` had `stack/structure/dependencies` keys; the only
file created was a `state/` entry). Fix init → less improvisation → lower cost. (P3 read-path has nothing to load
until init actually writes `MEMORY.md`/`PROJECT.md`/rules.)

### Resolved / downgraded
- `session_id` writer/reader match: **OK in this run** — the skill used `${CLAUDE_SESSION_ID}=5290…` and the gate
  read `state/5290….json`; the gate fired correctly. The 01 §4.1 `[uncertain]` did not bite here. (Low residual risk only.)

### Scope caveat (apply asymmetrically)
These are **headless `claude --print`** runs; ClaudeHut targets **interactive** sessions too (multi-turn, user
confirms phases) — interactive behavior is **[not measured]**. But Finding #2 is a hook-wiring code fact and
holds universally; #3/#5/#6 are confirmed in headless and plausibly milder interactively. Do not discount #2 with
the headless caveat.

## Finding #7 — path-scoped rules have a CREATE-time load gap (measured) — HIGH for tech-stack coverage

4 live A/B probes with arbitrary-marker rules (~$13; `evals/rule-load-probe.sh`, `rule-glob-probe.sh`,
`rule-tiebreak-probe.sh`):

| Surface | EDIT existing matching file | CREATE fresh matching file |
|---|---|---|
| **always-on** rule (no `paths:`) | reliably followed (~6/6) | reliably followed |
| **path-scoped** rule (`paths: **/*Entity.java`, the plugin's form) | **3/3 (loads on read)** | **0/3 (does NOT fire)** |

Native behavior: a `.claude/rules/` `paths:` rule loads "when Claude **reads** a file matching the pattern" —
so **creating** a new matching file (no prior read) does **not** trigger it (reproduced 0/3). Glob form is fine
(`**/*.java`, `*Entity.java`, `**/*Entity.java` all fired 3/3 on edit); the variable is read-vs-create, not the glob.
(Probe-1's initial 0/6 was a grep artifact — the agent paraphrased a hyphen+digit marker — corrected by robust
single-token re-runs.) **[`-p` headless only; interactive sessions unmeasured.]**

**Impact:** the plugin's **entire tech-stack rule layer is path-scoped**, so at **create-time** (new
Controller/Entity/Service/Listener — the common build action) the matching standard is **silently absent**; only
edits to existing files receive it. Adding path-scoped *or* description-triggered *skills* does **not** fix this
(same create-gap / soft-invoke). **Fix:** deliver create-time tech-stack depth from a reliably-loaded surface —
**preloaded into `claudehut-implementer`** (`skills:` frontmatter → full content in context at startup, independent
of file reads) and/or **always-on** rules — not solely path-scoped. (This also reframes the "add domain skills"
request: their value is *preload reliability*, not description-triggering.)

**Follow-up done — tech-stack best-practice playbooks (context7-researched).** Built 9 domain playbooks under
`skills/implement/references/` (web, jpa, reactive, messaging, caching, security, persistence-ops, testing,
java-lang), researched against current docs via context7 (Spring Boot 3.4, Hibernate 6, Reactor/Spring 6.2,
Spring Kafka 3.x, Spring Data Redis, Spring Security 6.5, Flyway/HikariCP, JUnit 5/Testcontainers, MapStruct/
Lombok) — spot-checked current (e.g. `@MockitoBean` not `@MockBean`, `@ManyToOne` default-EAGER, Security-6
lambda DSL). The 8 old granular refs were folded in (one home; rules stay terse, edit-time). The `implement`
skill (preloaded into the implementer) now maps each component → its playbook and instructs **read the playbook
when CREATING** (covers the #7 create-gap). Suite green: gate 21/21, conformance 49/49, init 36/36, ranker 5/5.

**Residual — NOW MEASURED (`evals/playbook-read-probe.sh`).** The earlier-flagged soft Read is the question:
with the `implement` skill body in context (the reliable part — preloaded into the implementer), does the agent
actually OPEN the matching deep playbook (`references/<x>.md`) when CREATING a new component? Live probe,
sanitized plugin (hooks stripped so the read-only measurement can't thrash on a denied write), **neutral**
create prompts (never mention "playbook"/"references" — the skill body must be what drives the read), detectors
verified against raw stream-json before scaling (declined vs path-failed distinguished).

| condition (neutral create) | skill loaded | matching playbook read **before** the write | errored Read (path-fail) |
|---|---|---|---|
| Spring MVC controller → `web.md` | 3/3 | **3/3** | 0/3 |
| JPA entity → `jpa.md` | 3/3 | **2/3** | 0/3 |
| **pooled (N=3/condition)** | **6/6** | **5/6 (83%)** | **0/6** |

(+ 2/2 detector-validation trials → **7/8 (88%)** overall.) **Headline:** the soft create-time Read **fires
reliably (5/6)**, and — the bug the design feared — the **relative `references/x.md` the skill table hands the
model resolves correctly to the plugin dir** (0/6 path errors; skill-loaded relative refs resolve against the
skill's own dir, not CWD). The lone miss (entity #2) was a clean **decline**, not a path failure — and its
`OrderEntity` still came out correct (`@Entity`/`@Id`, **no `@Data`/`@Builder`/`@EqualsAndHashCode`**): the
**preloaded skill-body conventions are a reliable floor** that caught the anti-pattern even without the deep
playbook. Decision rule (locked pre-run): R ≥ 5/6 → "create-time consult reliable." But web/jpa are the *easy* domains
(model succeeds from training anyway), so the verdict needed the **high-value** domains —
`security`/`messaging`/`reactive`, where a skipped playbook is a real defect (`playbook-read-probe-hv.sh`).

**Full measured read-before-write (15 trials, all skill_active 15/15, 0 path-resolution errors):**

| domain | playbook | read-before-write | consequence of the miss |
|---|---|---|---|
| MVC controller | `web.md` | 3/3 | — |
| JPA entity | `jpa.md` | 2/3 | **benign** — declined trial's `OrderEntity` was trivial + correct (no `@Data`) |
| **Spring Security** | `security.md` | 2/3 | **REAL DEFECT** — declined trial emitted `.anyRequest().permitAll()` (open door) |
| Kafka consumer | `messaging.md` | 3/3 | — |
| WebFlux handler | `reactive.md` | 3/3 | — |
| **pooled** | — | **13/15 (87%)** | misses are **not** uniformly benign |

**Verdict — the rate PASSED but the rate was the wrong test.** 13/15 (87%) cleared the pre-registered R ≥ 5/6
bar; on its own terms the read is reliable. The honest finding is not "the rate fell short" — it is "the rate
cleared the bar and was *still* insufficient," because read-rate can't see that one of the two misses is an open
door. What actually matters is the **consequence of a miss**, and it is domain-dependent: the skill-body floor
(DI / thin-controller / tx) does **not** carry deny-by-default, fetch strategy, or idempotency, so a *security*
skip produced an actual vulnerability (`permitAll()`) while a *trivial-entity* skip was harmless. The "floor
catches it" claim holds only for well-known/trivial patterns, not the deep content these playbooks exist to
supply. `[claude -p headless only; interactive unmeasured. Whether the downstream Review phase would catch a
slipped permitAll() is a separate, unmeasured backstop — not claimed as mitigation here.]`

**Therefore — hardening is warranted (proposed, NOT applied; needs approval per gate discipline).** Make the
high-cost create-time guidance survive a declined Read by inlining each high-value playbook's **single top
must-do** into the *preloaded* `implement` skill body — turning deny-by-default from an *action-dependent Read the
model can decline* into *passive always-in-context that shapes generation with no action required* — keeping the
full playbooks as on-demand depth. Minimum set, by measured risk: **security → deny-by-default, never
`permitAll()` as default**; jpa → set fetch type / guard N+1; messaging → idempotent consumer + manual ack;
reactive → never block the event loop. Cost: ~10 lines in the skill body.

**Fix APPLIED + VALIDATED (defect-rate, not read-rate — `evals/playbook-fix-validate.sh`).** Inlined the four
must-dos into the preloaded `implement` skill body (`skills/implement/SKILL.md`). Acceptance criterion: the
produced `SecurityConfig` must contain **no** `.anyRequest()…permitAll()` default and **no**
`WebSecurityConfigurerAdapter`, *even when the playbook is not consulted*. Result across **10 security trials, 0
open-door defects**:
- **N=5 normal** — 0/5 defects (all 5 happened to also Read the playbook, so this alone didn't isolate the inline; 1 trial wrote no config — a non-completion, not a defect).
- **N=4 ABLATION** (`… 4 ablate` — `security.md` deleted from the plugin copy, so the deep playbook is *unavailable*) — 0/4 defects.
- **+1 confirm trial, transcript-inspected:** `security.md` absent, **zero references reads issued** (true skip), yet the config emitted **`.anyRequest().authenticated()`** (deny-by-default) via a `SecurityFilterChain` bean. The skip-case: with the playbook unreadable the config was still deny-by-default (0 defects across these trials). The inline is the in-context instruction supporting that, and pre-fix a skipped read produced the `permitAll()` defect — so training alone isn't a reliable substitute. *(The trial count isn't powered to isolate the inline's effect from model variance — an N=4 baseline can't separate signal from a ~25-30% base rate. It's retained because the fix is correct and costless, not because N proves causation; the inline is monotonic — it can only reduce the defect, never introduce one.)*

**Verdict: residual CLOSED — measured, not asserted.** Create-time playbook Read fires 13/15 (jq-detected,
raw-transcript-verified; 0/15 path-resolution errors — relative `references/x.md` resolves to the plugin dir),
*and* the highest-cost guidance (deny-by-default) is now a passive always-in-context floor that holds at 0/10
defects including when the playbook is unreadable. Layered design works: playbook Read for depth, inlined floor
as the safety net for the cases a miss would be a vulnerability. *(Detector honesty: the validator's
`playbook_read` flag is a grep that matches the skill-body table text, not a real Read — irrelevant to the
defect-rate it measures; the 13/15 read-rate is the jq-based probe figure, not this grep.)* `[claude -p headless
only; interactive unmeasured.]`

## Prioritized optimization plan (gated — needs approval before applying)

Already applied (you approved): **P0 — P6 manifest load fix** (pure-metadata manifest; re-validated).

| # | Optimization | Closes | Evidence | Effort | Touches |
|---|---|---|---|---|---|
| 1 | **Arm the write gate at session start** — `bootstrap.sh` writes an initial `state/<session_id>.json` (`phase:brainstorm, reuse_scan:false`) so `gate-write.sh` denies production writes from turn 1 | #2 (HIGH) | 2/8 runs skipped the workflow; gate fail-open on missing state | small | `scripts/bootstrap.sh`, design 06 |
| 2 | **Canonicalize artifact paths** — `write-spec`/`write-plan`/`brainstorm` write under absolute `${CLAUDE_PROJECT_DIR}/.claude/claudehut/{specs,plans,reuse-scan-*.md,learnings.jsonl}`; `claudehut-state set-*` stores/validates canonical paths | #5 (HIGH) | spec 0/6 & plan 0/6 canonical; learnings 2/6 wrong path → P3 `@import` + P5 dead | small–med | skill bodies, `bin/claudehut-state`, design 04/07 |
| 3 | **`claudehut-init` must GENERATE the project plane** — write `MEMORY.md`/`PROJECT.md`/`LANGUAGE.md`/`architecture.md`/`reuse-index.json` + `.claude/rules/` (stack-gated), not emit JSON to stdout | #3/#4 (HIGH/MED) | post-init only a `state/` file; agent improvised `.claudehut/`; cost $2–3.7/run | medium | `skills/claudehut-init`, design 05/07 |
| 4 | **Gate verifies artifact existence under canonical root** (not just state flags) | #6 (MED) | gate opened on `set-reuse-scan --artifact .claudehut/…` that wasn't durably present | small | `scripts/gate-write.sh` or `verify-subagent.sh`, design 06 |
| 5 | **Cost reduction** — inline 3-subagent Brainstorm + 5-auditor Review = ~$2.8/trivial run (~18× baseline); consider sizing auditors to diff size / a lighter path for small changes | efficiency | mean ~$2.8/run, 4/7 hit $3 cap | medium | agents/skills · **[beyond documented scope]** — cost is not a stated objective; raised per the "benchmark" ask, not scored as a gap |

Harness improvements already landed (not plugin changes): `evals/conformance.sh` (+manifest-regression check),
`evals/ranker-tests.sh`, `evals/run.sh` (state-based scoring, `--trials`, leak guard), and the **load-probe**
(`system/init.plugin_errors`) as the authoritative P6 check.

## Re-validation (after applying approved opts #1–#4) — measured

Deterministic: **gate-tests 20/20** (was 17; +3 for #1 engaged-guard, #2 canon-reject, #4 missing-artifact),
**conformance 49/49**. One live re-run (`reuse-exists`, init-first) inspected on disk:

| Aspect | Pre-fix | Post-fix | Verdict |
|---|---|---|---|
| reuse-exists pass@1 | 0 (oracle missed non-canonical reuse-scan) | **1** | **#5 FIXED** |
| reuse-scan / spec / plan canonical | reuse 3/6, **spec 0/6, plan 0/6** | **reuse✓ spec✓ plan✓** under `.claude/claudehut/` | **#2 FIXED** |
| wrong-dir `.claudehut/` created | yes (`index.json`, `rules-src-*`) | **none** | **#2 FIXED** |
| gate opens on… | state flags only | canonical artifact **files exist** | **#4 working** |
| armed state at session start | none (fail-open) | **`{phase:brainstorm, reuse_scan:false}` present** | **#1 CONFIRMED** |
| slugify duplication | 1 (reuse ok) | 1 | P4 holds |
| **init project-plane files** (MEMORY/PROJECT/…) | none written | **still none written** | **#3 NOT fixed** |
| workflow completed | varies | capped at `implement` ($3.69) | #3 cost persists (accepted) |

**#3 honest result:** strengthening the init *skill instructions* was **not** sufficient — in headless the agent
still did not persist the project plane. Proper fix: make `claudehut-init` a **deterministic script** that writes
the templated files (don't rely on the model), and/or raise its budget. Recommended as a follow-up; #3 remains open.

**Update — follow-up BUILT (execution side):** `bin/claudehut-init` (deterministic generator: detects stack →
renders memory templates + stack-gated rules + `@import`, idempotent, never clobbers `learnings.jsonl`) and
`evals/init-tests.sh` now exist. Execution verified **33/33** across 4 fixtures (incl. synthetic reactive-kafka +
servlet-jpa): plane files written, stack-gating correct, base-package exact, `@import` idempotent. The init skill
is now script-first (runs the binary, then optional enrich).

**P7 (live, gated) — measured the invocation half.** 3 init-only trials + 1 full run ($8.3):
- **2/3** init trials produced the full plane (5/5). Trials 1–2: skill invoked **and** `bin/claudehut-init` ran →
  plane 5/5. **Trial 3: skill invoked but the `!`backtick`` script did NOT run** → plane 0/5. So the skill's
  `!`backtick`` **invocation is flaky** (the predicted risk) — *execution* is perfect, *invocation* via the skill is not.
- P7b full `reuse-exists`: pass@1=1, canonical reuse/spec/plan ✓ (workflow consumes canonical artifacts end-to-end),
  capped at review ($4.53) — cost issue #3 persists.

**#3 CLOSED via the FALLBACK (model-independent).** Since the skill `!`backtick`` path is unreliable, `bootstrap.sh`
(SessionStart) now runs `bin/claudehut-init` directly when `.claude/claudehut/` is absent — removing the model from
invocation entirely. Closure rests on a model-independent chain: (1) the SessionStart hook fires `bootstrap.sh` in
real `-p` sessions — **observed** (the load probe showed `hook_started SessionStart`); (2) `bootstrap.sh`→init writes
the plane when absent — **deterministically proven** (the `init-tests.sh` fallback test pipes the exact SessionStart
payload to `bootstrap.sh`, no `claude` in the loop → plane 5/5 + state armed + no wrong-dir). No further live run is
needed because the fallback's correctness does not depend on model behavior.
Deterministic suite after all changes: **gate-tests 21/21, conformance 49/49, init-tests 36/36, ranker 5/5.**
The init skill remains for explicit `/claudehut:init --refresh` + the enrich pass; the script is shared by both paths.
Hot-path checks on the changed `bootstrap.sh` (free): SessionStart runs in **~1s** (≪15s budget) and emits **clean
hook JSON** (no stdout leak from the generator), plane 5/5.

**Known residual (handoff, not blocking):** the *explicit* `--refresh`/enrich entry point still rides the skill's
flaky `!`backtick`` invocation (P7: 2/3). First-run bootstrap is fully covered by the deterministic SessionStart
fallback; an explicit re-init could still no-op if the model skips the `!`backtick``. If that proves annoying in
practice, route `--refresh` through the same hook-side script call.

### Net assessment (don't overclaim)
- **Confirmation strength differs.** #1 (arm), #2 (canon **rejection**), #4 (existence-check) are **deterministic**
  — guaranteed by gate-tests 20/20. #2 (agent **produces** canonical artifacts) and #5 (oracle 0→1) are
  **mechanism-forced + one live run** — defensible (non-canonical paths are now a dead end) but **n=1, not
  replicated** (budget hit the $25 ceiling). Hold them to the lower bar.
- **The fixes traded hollow-completion for correct-but-incomplete.** Pre-fix runs "completed" (phase=learn,
  review=pass) *because the gate was lax* — flag-only, so spec/plan pointed at non-canonical files and the run
  sailed to learn with artifacts that broke P3/P5. That was a **hollow completion**; the earlier "completed 4/8"
  was inflated by the very bug #2/#4 fix. Post-fix, the stricter gate forces real canonical artifacts but the
  run no longer reaches learn within $3 (capped at implement, $3.69). **So #3 (init + cost) is now the binding
  constraint** — until the workflow completes a trivial task within a sane budget, the correctness wins can't be
  realized end-to-end. #3 is the critical path, not a side issue.
- **Possible cost regression (watch-item, n=1):** $3.69 capped-at-implement (post) vs $2.95 reaching-learn (pre)
  — the stricter gate may add denial-retry friction. n=1 can't separate that from variance; resolve with a 2–3
  trial post-fix mini-matrix when budget reopens.
- **Minor inconsistency:** `claudehut-state set-phase --spec/--plan` flags still bypass `canon()` (only the
  dedicated `set-spec`/`set-plan`/`set-reuse-scan` validate). #4's existence-check backstops it (not exploitable),
  but worth tightening in the next pass.

## Spend
Measured live spend ≈ **$24** (top of the approved $15–25 envelope: probes ~$0.5 + smoke $0.75 + diagnostic $2.0
+ 6-run matrix $17.1 + re-validation $3.69). Further runs (e.g. re-testing a scripted init) would need a new go-ahead.
Original line preserved below for provenance:
Measured live spend ≈ **$20** (load/diagnosis probes ~$0.15 + smoke $0.75 + diagnostic $2.00 + 6-run matrix
$17.1). Within the approved Standard (~$15–25). No fabricated numbers; `[not run]`/`[uncertain]` marked where applicable.

## Acceptance status
Every documented objective mapped to a measured criterion (untestable ones `[uncertain]`); strategy approved
before running; existing harness reused/extended; multi-trial + variance reported; P6 fix approved + re-validated.
Remaining optimizations (1–5) await the Optimization Gate.

---

## v0.6.0 addendum (audit response + ponytail minimalism layer)

Full changelog: `.claude/prompt/update-v0.6.0/CHANGES-v0.6.0.md`. Deterministic-suite deltas after the upgrade:

| Suite | before | after | added |
|---|---|---|---|
| conformance | 83 | **93** | C11: slash recorder, failure capture, new-script exec, minimalism D1/D2/D3, `.worktreeinclude`, repo-fix |
| init-tests | 39 | **42** | `.worktreeinclude` create + seed + no-clobber |
| gate / ranker / worktree / merge-learnings | 71 / 8 / 18 / 14 | **unchanged, all green** | — |
| `loc-metric.sh --self-test` | — | **new, ok** | net-LOC + reuse-rate parser (D4) |

**Cost/reliability (P2) — live run on the v0.6.0 release (2026-06-23, `claude` 2.1.185, sonnet, $3/task cap,
claudehut mode, n=1, `evals/results/claudehut.jsonl`):**

| task | pass@1 | workflow | canonical r/s/p/l | $/run (incl init) | terminal |
|---|---|---|---|---|---|
| reuse-exists | 1 | **completed (learn, review=pass)** | T/T/T/**T** | $3.34 | capped |
| clean-first-run | 1 | capped in implement | T/T/T/F | $3.49 | capped |
| implement-skill-bypass | 1 | capped in implement | T/T/T/F | $3.39 | capped |
| shortcut-attempt | 1 | capped in implement | T/T/T/F | $3.37 | capped |
| review-catches-defects | 0 | capped in implement | T/T/T/F | $3.28 | capped |

- **No regression:** the plugin loads and drives in all 5 (reuse_scan=true everywhere) after the v0.6.0
  hooks/script changes. **pass@1 = 4/5** — the one miss (`review-catches-defects`) was **capped mid-implement
  before Review ran**, a budget artifact, not a review-rigor failure.
- **`review-catches-defects` re-run at the $6 cap → pass@1=1, completed (review=pass), terminal=success,
  $6.27, canonical 4/4.** With adequate budget the full 7-phase workflow completes and the **D2 review rigor
  catches/prevents all 4 seeded defects** (N+1, EAGER collection, missing `@Valid`, entity-as-`@RequestBody`)
  and reaches an earned `review=pass` — confirming the $3 result was purely a budget artifact and the
  minimalism/rigor review lens works live.
- **Canonical store now works: spec & plan landed canonical in 5/5** (this report's earlier matrix measured
  **0/6**). The `tasks/NNNN-<slug>/` store + the score.sh/run.sh canonical-path reads are confirmed end-to-end.
- **Cost confirms P2:** **5/5 hit the $3 cap** (~$3.4/run incl init ≈ 24× the $0.142 baseline; truncated by the
  cap, so a floor). The workflow needs >$3/run on sonnet to complete most tasks — exactly the tension the cost
  levers target. The realized levers are **D (less generated code)** + **B3 (fewer fast-lane dispatches)**;
  **B1 model/effort tiering** remains the highest-impact measured experiment (design below). Use `loc-metric.sh`
  for the LOC side; report only measured numbers (no fabricated savings %).
**B1 model/effort tiering is deliberately deferred to a measured A/B experiment** — plugin-subagent model is
frontmatter-fixed (no per-dispatch override) and the review rigor contract requires opus+xhigh, so a blind
flip risks the lenient-review regression the plugin exists to prevent.

**Recommended design for the deferred cost experiment** (template adapted from the ponytail v4.7 agentic
benchmark, `benchmarks/results/2026-06-18-agentic.md` — built to *disprove* its own plugin):
- **Arms:** `baseline` (no plugin) · `claudehut` (full plugin) · a terse-prose control (isolates "is the win
  just brevity?") · optionally a one-line-YAGNI-prompt control (isolates "does a short instruction suffice?").
- **Metrics:** `net_loc_added` + `reuse_rate` (via `evals/loc-metric.sh`) · tokens · `$/run` · wall-time ·
  **safety scored by executing the produced code against adversarial input** (the minimalism cut must not drop
  a guard) — exactly the floor `loc-metric` can't see. n≥4 per (task, arm), fresh repo + fresh context per cell.
- **CONTAMINATION CAVEAT (ponytail caught this; it applies to us too):** ClaudeHut's own `bootstrap.sh`
  SessionStart hook would fire on the **baseline** arm and inject the workflow, silently contaminating it.
  Isolate each arm with `--setting-sources project,local` and a single `--plugin-dir` per arm so the plugin
  loads only where intended. Without this, the baseline is not a baseline.
- **Honesty boundary:** report only measured numbers; a "% saved" requires the real baseline arm above
  (`loc-metric.sh` documents this) — never a fabricated counterfactual.

**Carried-forward finding (now actionable):** `evals/score.sh` + the task `oracle.sh` files still grep the
**legacy flat** `reuse-scan-*.md`/`specs/`/`plans/` paths, not the canonical `tasks/NNNN-<slug>/` store — the
same drift behind the false "fail" #5. Fixing those paths so live scoring reads the canonical store is the
recommended next eval-harness task.
