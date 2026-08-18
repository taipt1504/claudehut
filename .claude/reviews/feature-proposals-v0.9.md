# ClaudeHut v0.9 — Feature Proposals

**Scope of this document:** research + proposal only. No plugin file was modified. Companion to
`.claude/reviews/plugin-audit-v0.8.md` (the v0.8 audit) — every recommendation traces to an audit finding,
a domain gap, or a verified platform change. Produced from three parallel research tracks (Claude Code
platform / ecosystem patterns / Java-Spring domain gaps) with source-cited claims; anything unverifiable is
marked **[uncertain]** and no recommendation depends on an uncertain API.

---

## 1. Platform-change summary (what changed in Claude Code that affects this plugin)

**Verdict: nothing v0.8 uses is deprecated.** All frontmatter fields and hook events v0.8 relies on are
currently documented and valid, and three of the v0.8 audit's `[uncertain]` items are now **resolved YES**:

| Audit open question | Resolution | Source |
|---------------------|-----------|--------|
| `defaultEnabled` a real `plugin.json` field? (audit ARCH-2) | **Yes** — "Whether the plugin starts enabled… Defaults to true. Requires Claude Code v2.1.154+." | https://code.claude.com/docs/en/plugins-reference |
| `effort:` a real subagent field? (audit AGENT-6) | **Yes** — documented: "Effort level when this subagent is active. Overrides the session effort. Options: low, medium, high, xhigh, max." | https://code.claude.com/docs/en/sub-agents |
| `skills:` / `isolation: worktree` real subagent fields? | **Yes** — both documented; "the only valid isolation value is `worktree`." | https://code.claude.com/docs/en/sub-agents |
| `UserPromptExpansion` a real hook event? (audit HOOK-3) | **Yes** — but the payload field is **`expansion`**, and the matcher filters on **command name**. v0.8's `record-skill-expansion.sh` reads `.expanded_prompt/.prompt/.user_prompt` (dead against the real schema; the primary `.command_name` path still works) and its matcher `implement\|discover\|brainstorm` may not match a namespaced `claudehut:implement`. | https://code.claude.com/docs/en/hooks |
| Prompt/agent (model-driven) hooks documented? | **Yes** — five hook types: `command, http, mcp_tool, prompt, agent`. `prompt` = "evaluate a prompt with an LLM"; `agent` = "run an agentic verifier with tools" (experimental). | https://code.claude.com/docs/en/hooks |

Also confirmed valid: `memory: project` on the learner agent ("Persistent memory scope… enables cross-session
learning", sub-agents doc) and `$schema` in plugin.json ("Claude Code ignores this field at load time").

**New capabilities since v0.8 was built (unlock opportunities):**

| Capability | What it enables | Source |
|-----------|-----------------|--------|
| **Model-driven hooks** (`prompt` / `agent` type) | A Stop/PreToolUse gate can call a fast model to judge completion/reuse instead of only pattern-matching a state file. | https://code.claude.com/docs/en/hooks |
| **`${CLAUDE_PLUGIN_DATA}`** persistent dir (`~/.claude/plugins/data/{id}/`) | State that "survives updates"; `${CLAUDE_PLUGIN_ROOT}` "changes when the plugin updates — do not write state here." Correct home for durable / cross-project memory. | https://code.claude.com/docs/en/plugins-reference |
| **~20 new hook events** — `SubagentStart`, `PostToolBatch`, `FileChanged`, `InstructionsLoaded`, `TaskCreated/Completed`, `PermissionDenied`, `WorktreeCreate/Remove`, `SessionEnd`, `PostCompact`, … | v0.8 uses 9 of ~30 events; several enable stronger enforcement/telemetry. | https://code.claude.com/docs/en/hooks |
| **`asyncRewake` hook field** | A background hook can wake Claude on failure with its stderr shown as a system reminder (vs. v0.8's async failures being silently swallowed). | https://code.claude.com/docs/en/hooks |
| **New skill frontmatter**: `paths`, `context:fork`, `agent`, `hooks`, `disallowed-tools`, `model`, `when_to_use`, `user-invocable` | `paths:` gives documented file-glob auto-activation for skills. | https://code.claude.com/docs/en/skills |
| **Background Monitors** (v2.1.105+) and **LSP servers** as plugin components | Continuous watchers; inline compiler diagnostics for reviewers. | https://code.claude.com/docs/en/plugins-reference |
| Docs host moved: `docs.claude.com/en/docs/claude-code/*` **301-redirects** to `code.claude.com/docs/en/*` | Update any doc links to avoid redirect churn. | https://code.claude.com/docs/en/hooks |

**One deprecation-adjacent correctness note (not a deprecation):** `record-skill-expansion.sh`'s fallback
field names don't match the documented `expansion` schema — see candidate **C11**.

---

## 2. Scored candidate table (12)

Impact 1–5 (higher = more value) · Effort S/M/L · Risk 1–5 (higher = riskier) · Fit 1–5 (fit with the
7-phase architecture). ★ = Top-5 recommendation (detailed in §3).

| ID | Candidate | Addresses | Impact | Effort | Risk | Fit | Verdict |
|----|-----------|-----------|:------:|:------:|:----:|:---:|---------|
| C1 | Advisory lock on the learnings read-modify-write | audit **MEM-1** | 3 | S | 2 | 4 | ★ Rec 1 (part) |
| C2 | Memory hygiene: deterministic supersede + regenerate-from-store rule promotion + usage/age **retirement** | audit **MEM-2/3/4** | 4 | L | 3 | 5 | ★ Rec 1 (part) |
| C3 | Learning **ingest sanitization** + inject-time untrusted-delimiting | audit **SEC-1** | 4 | M | 2 | 5 | ★ Rec 1 (part) |
| C4 | `claudehut-contract-reviewer` — event (Kafka/Avro/Pact) + REST/gRPC **schema-compat** auditor | domain gap: messaging & API contract testing | 5 | L | 2 | 5 | ★ Rec 2 |
| C5 | `claudehut-observability-reviewer` — metrics/tracing/SLO gate | domain gap: observability beyond `logging-mdc` | 4 | M | 2 | 5 | ★ Rec 3 |
| C6 | Eval coverage & self-check pack: mermaid presence/parse guard + per-task reference solution + profile-rail gate-tests | audit **EVAL-1 / EVAL-2** | 4 | M | 1 | 5 | ★ Rec 4 |
| C7 | Model-driven gate augmentation: `prompt`/`agent` hook on Stop (script gate stays as backstop) | platform: model-driven hooks | 4 | M | 3 | 4 | ★ Rec 5 |
| C8 | Upgrade-safety capability: `framework/upgrade-safety.md` rule + "upgrade" task-shape sub-flow | domain gap: dependency/framework bumps | 4 | L | 3 | 4 | Table (fast-follow) |
| C9 | `framework/config-safety.md` rule pack (profile/env drift, `@Validated` config beans) | domain gap: config & profile drift | 3 | S | 1 | 4 | Table |
| C10 | Adversarial competing-hypotheses critic round in Review (auditors challenge each other's clears) | Review robustness / self-audit theme | 3 | M | 3 | 4 | Table |
| C11 | Fix `record-skill-expansion.sh` to read `expansion` + verify matcher matches `claudehut:*` | audit **HOOK-3** + platform schema | 2 | S | 1 | 3 | Table (quick fix) |
| C12 | Durable memory via `${CLAUDE_PLUGIN_DATA}` (survive updates; optional cross-project scope) | platform: persistent data dir | 3 | M | 3 | 4 | Table (strategic) |

---

## 3. Top 5 recommendations

### Rec 1 — Memory-engine hardening (C1 + C2 + C3)
**What.** Turn the learning/memory subsystem from monotonic-growth-with-no-locking into a safe, bounded,
self-correcting store, in three coordinated changes:
- **C1 lock:** wrap `merge-learnings.sh`'s whole load→merge→atomic-`mv` in a portable advisory lock
  (`mkdir`-lockfile with a stale-lock timeout, or `flock` on a `.lock`) so concurrent Learn passes serialize.
- **C2 hygiene:** when a candidate declares `supersedes:<id>`, deterministically mark the old entry
  `status:superseded` and exclude it from injection ranking (a plain max-serial/timestamp rule — no LLM
  freshness judgment); replace the append-only (`>>`) rule promotion with a **regenerate** step that rewrites
  the whole auto-promoted block from the current promoted+live set each pass (so retired lines disappear);
  add a compaction pass that can retire even `hits≥2` entries via time-since-last-**applied** decay, and reset
  `.recurrence` after N quiet sessions.
- **C3 sanitization:** at ingest (`harvest-candidates.sh`/`merge-learnings.sh`) strip/neutralize
  directive-looking spans and URLs from `.learning`/`.evidence`; at inject (`inject-learnings.sh`) wrap each
  entry in a randomized delimiter the SessionStart context labels as opaque untrusted data.

**Why now.** This is the audit's #2 verdict and the plugin's most novel-yet-least-defended subsystem. Left
as-is it can lose data (MEM-1), grow unbounded (MEM-2), carry stale/contradictory promoted rules forever
(MEM-3), re-inject a fixed pitfall at 2.5× forever (MEM-4), and persist unsanitized text into future prompts
(SEC-1). The v0.8 review-finding harvest path is the exact untrusted surface.

**Addresses.** MEM-1, MEM-2, MEM-3, MEM-4, SEC-1.

**Files.** `scripts/merge-learnings.sh`, `scripts/inject-learnings.sh`, `scripts/harvest-candidates.sh`,
`scripts/learning-score.sh`; tests `evals/merge-learnings-tests.sh`, `evals/gate-tests.sh`.

**Effort.** L (locking S; supersede/regenerate/decay M–L; sanitization M).

**Acceptance criteria (for later implementation).**
- Two concurrent `merge-learnings.sh` runs on the same store lose zero entries (a test spawning two writers
  asserts both new learnings + both `hits` bumps survive).
- A candidate with `supersedes:<id>` causes the old entry to be excluded from `inject-learnings.sh` output,
  and a superseded/decayed promoted line is **absent** from the rule file after the next Learn pass.
- An entry with `hits≥2` whose last-applied timestamp is older than the decay TTL is retired by compaction;
  `.recurrence` resets to 0 after N quiet sessions (unit-tested).
- A learning containing a directive/URL is stored with that span neutralized, and every injected entry is
  wrapped in the untrusted-delimiter marker (asserted by `inject-learnings.sh` output test).
- No new runtime dependency; scripts pass `bash -n` and degrade on missing `jq`/`flock`.

### Rec 2 — `claudehut-contract-reviewer` (C4)
**What.** A new Review-phase auditor spawned by `skills/review/SKILL.md` when the diff touches messaging
listeners/producers, Avro/Protobuf/`*.avsc`/`*.proto` schemas, or REST controllers/OpenAPI. It verifies:
(a) a consumer-driven/provider contract test exists for each new/changed event (Spring Cloud Contract or
Pact); (b) schema evolution is BACKWARD/FULL compatible (no removed/renamed required fields, no type
narrowing); (c) events carry a schema version and consumers tolerate unknown fields; (d) DLQ + replay is
test-asserted; (e) for sync APIs, an oasdiff-style breaking-change classification on the committed OpenAPI /
gRPC proto (field-number reuse, added required request field, removed field, changed status contract) blocks
absent an explicit version bump. Emits the same cited coverage table as the other auditors.

**Why now.** Verified gap: `claudehut-db-reviewer` gates the *relational* schema, `claudehut-perf-reviewer`
only reads consumer lag, and `references/messaging.md` covers runtime idempotency/DLQ but **not**
schema-compat or contract tests. Broken message/API contracts are among the most expensive Spring-backend
production failures and are invisible to the current auditor set.

**Addresses.** Domain gaps: Kafka/messaging contract testing + REST/gRPC backward-compat (merges the
research's separate "api-compat" candidate).

**Files.** New `agents/claudehut-contract-reviewer.md`; edit `skills/review/SKILL.md` (dispatch trigger +
reviewer-selection table); optional new rule `templates/rules/framework/contract-compat.md`; new eval task
under `evals/tasks/`.

**Effort.** L.

**Acceptance criteria.**
- On a fixture diff that renames a required Avro field, the auditor returns a CRITICAL/HIGH `✗` row citing
  the schema `file:line`; on a purely additive optional-field change it returns `✓`.
- On a fixture removing a REST response field without a version bump, it returns a breaking-change `✗`.
- Produces the standard coverage table (one row per changed event/endpoint, each with a cited locus) and is
  read-only (no `Bash` write grant — per audit AGENT-2).
- `skills/review/SKILL.md` documents the exact diff signals that spawn it.

### Rec 3 — `claudehut-observability-reviewer` (C5)
**What.** A Review-phase auditor that treats observability as a first-class gate: for each new/changed HTTP
endpoint, message listener, scheduled job, or outbound client it verifies (a) a Micrometer meter /
`@Observed` instruments latency + error count, (b) trace context propagates (Micrometer Tracing / OTel bridge;
Reactor-context or MDC on the reactive path), (c) an SLO-bearing timer exists where the spec set an NFR
latency target, (d) error paths increment a counter and log at the right level.

**Why now.** Verified gap: `logging-mdc.md` covers structured logging only; no component checks
metrics/tracing/SLOs, yet `minimalism.md` already assigns observability "floor item" status — the gate is
promised but unenforced.

**Addresses.** Domain gap: observability review.

**Files.** New `agents/claudehut-observability-reviewer.md`; edit `skills/review/SKILL.md` (reviewer-selection
table); optional `templates/rules/observability/instrumentation.md`; new eval task.

**Effort.** M.

**Acceptance criteria.**
- On a fixture adding an HTTP endpoint with no Micrometer instrumentation, returns a `✗` row citing the
  handler `file:line`; with a `@Timed`/`@Observed` present, `✓`.
- When the spec carries an NFR latency target, the auditor requires a matching SLO timer or marks `✗`.
- Read-only (no write grant); standard coverage-table output.

### Rec 4 — Eval coverage & self-check pack (C6)
**What.** Three deterministic additions: (1) a conformance assertion that every `agents/*.md` and
`skills/*/SKILL.md` that shipped a ` ```mermaid ` fence still has a non-empty one, piped through a CLI parser
(`@mermaid-js/mermaid-cli` or a lightweight syntax check) **skipped-if-absent** so CI stays hermetic; (2) a
`reference.md` known-good output per `evals/tasks/<t>/` that MUST pass that task's `oracle.sh`, run in CI so a
broken/over-strict oracle fails fast; (3) `gate-tests.sh` unit cases for `profile=audit/investigation`
(findings-path required, audit-is-engagement fail-open, learn-receipt-on-non-trivial, and the park-and-wait
fail-open by name).

**Why now.** Audit EVAL-1 (20 of 21 ultra-flow diagrams uncovered — a future edit can ship a broken diagram
with CI green) and EVAL-2 (the profile rail is exercised only incidentally in `conformance.sh`). Lowest-risk
high-value item: it is test-only and hardens everything else v0.9 adds.

**Addresses.** EVAL-1, EVAL-2.

**Files.** `evals/conformance.sh`, `evals/gate-tests.sh`, new `evals/tasks/*/reference.md`; a small guard step
mirrored in `.github/workflows/ci.yml` **(note: CI file is out of the Prompt-2 apply scope — propose the eval
scripts; wire CI as a follow-up).**

**Effort.** M · **Risk.** 1 (tests only).

**Acceptance criteria.**
- Deleting a `mermaid` block in any shipped skill/agent makes `conformance.sh` fail locally.
- Each `evals/tasks/<t>/reference.md` passes its own `oracle.sh` (a CI step asserts this for all tasks).
- `gate-tests.sh` has ≥4 named cases covering the audit/investigation completion rail; battery total rises and
  stays 0-failed.

### Rec 5 — Model-driven gate augmentation (C7)
**What.** Add a `prompt`-type (or experimental `agent`-type) hook on the **Stop** event that asks a fast model
to judge whether the completion claim is backed by fresh test evidence — **alongside**, never replacing,
`gate-done.sh`. The deterministic script gate remains the hard backstop (fail-closed); the model hook is an
additive judgment layer that can catch "looks-passing-but-isn't" cases the pattern gate cannot.

**Why now.** Model-driven hooks are a newly-documented first-class hook type
(https://code.claude.com/docs/en/hooks); v0.8's gates are script-only. This is the marquee new-capability
unlock and directly strengthens the enforcement spine the plugin is built around.

**Addresses.** Platform change (prompt/agent hooks); strengthens the Review→done gate.

**Files.** `hooks/hooks.json` (add the `prompt`/`agent` hook entry on `Stop`); a prompt template file; docs in
`README.md`. `scripts/gate-done.sh` unchanged (remains the backstop).

**Effort.** M · **Risk.** 3 — model latency/cost on the Stop path and nondeterminism; **mitigation:** keep the
script gate authoritative, cap the model hook with a short timeout, and make it advisory-then-blocking only on
a high-confidence "no evidence" verdict.

**Acceptance criteria.**
- The script `gate-done.sh` decision is unchanged when the model hook is disabled (backstop preserved).
- The model hook is defined with an explicit `timeout` and a documented model id; on timeout/error it
  **fails open** (never wedges the session), consistent with the plugin's fail-open invariant.
- A fixture "green claim with a red/stale test" is blocked by the combined gate; a genuinely-passing task is
  not blocked.
- `hooks/hooks.json` passes `jq empty`.

---

## 4. Rejected / deferred (with reasons)

| Candidate | Reason |
|-----------|--------|
| LSP diagnostics in Review (ship jdtls config) | Adds an external toolchain dependency + config surface; high value but against the "no new deps" constraint — revisit as a strategic opt-in. |
| `FileChanged` reindex Monitor | Speculative — no proven index-staleness pain today; adds a background watcher for an unquantified benefit. |
| `InstructionsLoaded` rule-load audit | Useful telemetry but low urgency; no finding/gap forces it now. |
| Convert path-scoped rules to skills with `paths:` frontmatter | Would rewrite a working rule-scoping mechanism for marginal gain; risk > reward this cycle. |
| `asyncRewake` on async hooks | Minor UX polish (surfacing background lint failures); fold into a later hooks pass. |
| Separate REST/gRPC "api-compat" auditor | **Merged into C4** (`claudehut-contract-reviewer`, sync + async modes) to avoid two overlapping auditors. |
| New standalone test-quality auditor | Mostly covered — `testcontainers.md`, `coverage.md`, and `claudehut-test-runner`'s flaky rerun exist; fold only the new "each AC-xxx traces to a test" idea into `references/review-rigor.md`. |
| `pretooluse-write-gate-as-agent-hook` (agent verifies reuse-scan covers the file) | Fold into C7's model-gate direction as an optional second hook; not a standalone v0.9 item. |
| Secret redaction + auto-gitignore `state/` (audit **SEC-2**) | Not a *new capability* — it is the audit's #1 quick-win fix and already lives in the v0.8 audit roadmap. **Prerequisite:** ship it as a bugfix before/with v0.9, independent of this proposal. |

---

## 5. Notes, caveats & sources

**Confidence.** All platform claims (§1) are verified against `code.claude.com/docs` (hooks, sub-agents,
skills, plugins-reference) and are load-bearing. Domain-gap claims are grounded in repo `file:line` reads of
the actual skills/agents/rules. Ecosystem techniques (locking, supersede-on-max-serial, usage/age decay,
write-path sanitization + inject-time delimiting, reference-solution grading, adversarial critic rounds) are
standard engineering practices and were also cross-checked against vendor/tool docs (below). **[uncertain]:**
several arXiv paper IDs the ecosystem track cited (e.g. `2606.01435`, `2605.01970`, `2606.04329`,
`2606.06240`) are future-dated and could not be independently confirmed — the *techniques* stand on general
merit and the verified vendor sources; the specific papers should not be cited as authority.

**Verified external sources (selected):**
- Platform: https://code.claude.com/docs/en/hooks · /sub-agents · /skills · /plugins-reference · /agent-teams
- Memory/eval patterns: https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents ·
  https://langchain-ai.github.io/langmem/concepts/conceptual_guide/ ·
  https://docs.cognee.ai/core-concepts/main-operations/memify · https://deepeval.com/blog/what-is-an-eval-harness
- Contract/API: https://github.com/oasdiff/oasdiff · https://www.oasdiff.com/ ·
  https://softwaremill.com/contract-testing-of-event-driven-application-with-kafka-and-spring-cloud-contract/ ·
  https://spoud-io.medium.com/avro-schema-evolution-handling-incompatible-versions-in-kafka-consumers-92af2808a835
- Observability/upgrade: https://spring.io/blog/2025/11/18/opentelemetry-with-spring-boot/ ·
  https://docs.spring.io/spring-boot/reference/actuator/metrics.html ·
  https://docs.openrewrite.org/running-recipes/popular-recipe-guides/migrate-to-spring-3
- Prompt-injection defense (technique class): https://zylos.ai/research/2026-04-12-indirect-prompt-injection-defenses-agents-untrusted-content/ **[uncertain — verify before citing as authority]**

**Traceability check.** Rec 1 → MEM-1/2/3/4 + SEC-1. Rec 2 → messaging/API contract gap. Rec 3 →
observability gap. Rec 4 → EVAL-1/EVAL-2. Rec 5 → platform (model-driven hooks). Table extras C8–C12 → dep-
upgrade gap / config-drift gap / Review robustness / HOOK-3 + platform schema / persistent-data platform
change. Every recommendation lists concrete target files and binary acceptance criteria above.

**For the v0.9 apply session (Prompt 2):** approve by Rec/candidate ID (e.g. "Rec 1, Rec 2, Rec 4"). Each
approved item's Files + Acceptance criteria here are the implementation contract.
