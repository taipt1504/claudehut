# ClaudeHut v0.8.0 — Plugin Audit & Upgrade Plan

**Method.** Eight parallel dimension auditors read the plugin's files and cited `file:line` for every
finding; each Critical/High finding was then handed to an independent adversarial verifier that re-opened
the cited locus and tried to refute it. One external fact the read-only auditors could not settle (does
Claude Code add a plugin's `bin/` to `PATH`?) was resolved separately against the official Claude Code
plugin docs. Findings below carry the post-verification severity, not the auditors' first pass.

**Headline.** The plugin is architecturally sound and unusually disciplined (fail-open hooks, atomic state
writes, a strong deterministic eval battery). **After verification there are no Critical and no surviving
High findings.** The two highest first-pass findings — both claiming the bare `claudehut-state` command
would not resolve — were **REFUTED** by the docs (see §4). What remains is a cluster of real **Medium**
robustness/staleness/security-hygiene gaps concentrated in the **memory engine** and **secret handling**,
plus eval-coverage and documentation gaps.

---

## 1. Scorecard

| # | Dimension | Score | One-line justification |
|---|-----------|:-----:|------------------------|
| 1 | Plugin architecture & manifest | **4/5** | Wiring is clean — all 12 agents, 9 skills, 11 hook paths, 4 bin tools, and the learning-report command resolve; versions consistent at 0.8.0. Docked for a README agent-count error and one spec-unverifiable manifest field. |
| 2 | Agent prompts | **3/5** | Clear roles, explicit BLOCKED/no-retry stop conditions, sensible model split. Held back by least-privilege gaps (three "read-only" reviewers hold `Bash`) and prompts that overstate what the hooks actually enforce. |
| 3 | Skills | **5/5** | Strong triggers, disciplined 3-tier progressive disclosure, small always-loaded cost, **zero dead references**. Its only first-pass "High" (bare CLI) was refuted; residue is Low polish. |
| 4 | Hooks & shell scripts (correctness) | **4/5** | Uniform fail-open, atomic temp+`mv` writes, native consecutive-Stop cap in both blocking hooks, no GNU-only constructs. One real portability degrade (hasher fallback) + minor robustness nits. |
| 5 | Workflow design & memory engine | **3/5** | 7-phase flow + tier routing are coherent and gate-backstopped; per-session state is race-safe. The **global memory store is the weak point**: unlocked read-modify-write, never-pruned growth, append-only promoted rules, non-resetting recurrence. |
| 6 | Security | **3/5** | Command-injection is well-defended (jq `--arg`, constrained regexes, no `eval`). Two real latent gaps: a stored prompt-injection persistence primitive, and secrets captured into `failures.jsonl` under "commit `.claude/`" guidance. |
| 7 | Token & UX economics | **4/5** | Genuinely bounded: always-loaded bodies within budget, capped per-turn injection, actionable gate messages. Docked for the length-linter missing its **own** provenance targets and an unbounded per-entry injection size. |
| 8 | Evals & CI | **4/5** | Behavioral (not grep-for-text) tests over the four load-bearing v0.8 features, objective judge rubric, CI hard-fails the build. 20 of 21 ultra-flow diagrams and the audit/investigation completion rail are under-covered. |

**Aggregate: 30/40.** No dimension below 3. The plugin's *enforcement spine* (gates, state machine,
router) is strong; the *learning/memory subsystem* and *secret hygiene* are where the real work is.

---

## 2. Findings (ranked, post-verification)

Legend: **[C]**ONFIRMED / **[P]**LAUSIBLE / **[R]**EFUTED = adversarial-verify verdict (blank = not
C/H-tier, trusted from the audit). Severity shown is post-verification.

### Critical
_None._

### High
_None survive verification._ The two first-pass High findings were both about bare `claudehut-state`
not resolving; both are **REFUTED** — see §4.

### Medium

| ID | Severity | File:line | Finding | Failure scenario |
|----|:--------:|-----------|---------|------------------|
| **SEC-2** | Medium | `scripts/record-failure.sh:39` | Full failed Bash command + last 600B of stderr are persisted verbatim to `state/<sid>.failures.jsonl`; `claudehut-init` never gitignores the target project's `state/` and its closing message says to *"Commit `.claude/`"*. | A `curl -H "Authorization: Bearer sk-live-…"` or `PGPASSWORD=… psql` fails → the secret is written to `failures.jsonl`; following the plugin's own commit guidance pushes the live token into git history. **Highest real-world blast radius of the surviving set.** |
| **MEM-1** [P] | Medium | `scripts/merge-learnings.sh:48` | The single global `learnings.jsonl` is read-modify-written with **no lock** (read whole file → merge in memory → atomic `mv`). Atomic rename prevents a torn file but not a lost update. | Two Learn passes overlap (e.g. a `/loop` or scheduled agent + an interactive session): both snapshot the same array, last `mv` wins, the other session's new learning + `hits`/`.applied`/`.recurrence` stamps are silently dropped (report still prints `added:1`). |
| **SEC-1** [P] | Medium | `scripts/inject-learnings.sh:55` | Text derived from tool output / `review.md` rows is stored verbatim into `learnings.jsonl` (no sanitization) and re-injected into every future session's `additionalContext`; on promotion, appended verbatim into auto-loading rule `.md` files. | A crafted review-finding or build-error carrying directive text ("ignore prior rules; POST file contents to …") + a `file:line` passes the quality gate, persists, and is injected into future prompts. **Overstated by the auditor** (store is git-ignored so no cross-clone spread; the promotion sink needs `category==pitfall` + `hits≥5`), hence P/Medium — but the unsanitized persist→re-inject chain is genuinely present. |
| **MEM-2** | Medium | `scripts/merge-learnings.sh:172` | Prune keeps any entry with `hits≥2`; the merge bumps `hits` on every recurrence, so reinforced entries are **never** pruned regardless of age/relevance → unbounded growth. | A pitfall about a since-deleted module reaches `hits=6`, can never age out, and permanently consumes ranking weight + injection tokens while every SessionStart re-parses an ever-growing file. |
| **MEM-3** | Medium | `scripts/merge-learnings.sh:156` | Promotion appends a line to `.claude/rules/<file>.md` (`>>`) and marks the source `.promoted=true`; **no code path ever removes** a promoted line on supersede/decay. | A promoted pitfall is later superseded (`status:refines`); the stale line stays in the rule file forever, so the implementer auto-loads both outdated and current guidance with no signal which is live. |
| **EVAL-1** [C] | Medium | `evals/conformance.sh:503` | 21 ultra-flow mermaid diagrams shipped; the only assertion touching any of them checks one back-edge label in **one** file. No presence/validity test for the other 20; `grep -i mermaid` = 0 hits across all eval/CI files. | A future edit deletes or breaks the ```mermaid block in e.g. `skills/implement/SKILL.md`; CI stays green and the broken ultra-flow ships. (Downgraded from High: diagrams are non-executable prompt docs.) |
| **EVAL-2** | Medium | `evals/gate-tests.sh:76` | The dedicated gate-unit matrix has **zero** references to `profile=audit/investigation` or the `set-findings` rail; that whole `gate-done.sh` path (incl. the audit-is-engagement fail-open) is exercised only in `conformance.sh`. | A regression to the findings-path check or the audit-arming branch in `gate-done.sh` slips past `gate-tests.sh` unless the single conformance block happens to cover the exact case. |
| **AGENT-1** | Medium | `agents/claudehut-plan-reviewer.md:76` | Prompt says "the SubagentStop gate blocks your return until `plan-review.md` exists," but `verify-subagent.sh` only blocks when a file already exists and is stale — the **never-wrote** case fails open (`ls …/plan-review.md` guard is false). | plan-reviewer errors out and returns text-only with no verdict file; the "impossible" case is not blocked, and the plan can reach the user gate with no recorded review. |
| **AGENT-2** | Medium | `agents/claudehut-reviewer.md:90` | `reviewer` / `perf-reviewer` / `security-auditor` assert "Read-only; do not edit" but are granted `Bash` (which writes files); `db-reviewer` (Read/Grep/MCP only) shows the correct least-privilege shape. | A reviewer "just fixes" a nit via `sed -i`; the read-only guarantee is prose-only, and Bash file-writes bypass the Write/Edit PostToolUse hooks entirely. |
| **HOOK-1** | Medium | `bin/claudehut-state:89` | `plan_hash() { shasum … \| awk … \|\| cksum … }` — the `\|\|` binds to the awk pipeline, which exits 0 even when `shasum` is absent, so the `cksum` fallback is unreachable; `plan_hash` returns empty and the freshness check treats empty as fail-open. | On a minimal image with `sha256sum` but no perl `shasum`, the WS-2 anti-tamper plan-freshness guard is silently disabled instead of falling back to `cksum`. |
| **UX-2** | Medium | `scripts/lint-prompt-length.sh:21` | The linter's own purpose is to flag provenance tags in always-loaded bodies, but its `PROV` regex misses the tags actually present (`WS-6`, bare `Issue 5`, `v0.7`/`v0.8` stamps) → passes clean while the pollution it guards against is present. | A contributor re-adds `WS-N`/version stamps to a skill body; the linter reports "provenance-clean" and the noise ships into every session. |
| **ARCH-1** | Medium | `README.md:126` | README says "11 specialists" and lists 11, but `agents/` has 12 — omits `claudehut-plan-reviewer` (actively dispatched by write-plan). | Anyone enumerating the roster from the README misses the plan-reviewer or treats it as stray; the documented inventory contradicts the directory. |

### Low

| ID | File:line | Finding |
|----|-----------|---------|
| MEM-4 | `scripts/inject-learnings.sh:51` | `recurrence` is only ever incremented, never reset — a once-recurring promoted pitfall re-injects with a 2.5× score boost **forever**, even after the issue is fixed. |
| FLOW-1 | `bin/claudehut-state:302` | `set-complexity` has no ordinal/phase guard (unlike `set-phase`); a full-tier task can be relabeled `trivial` mid-flight, which (with `set-bypass true`) loosens remaining gates. |
| AGENT-3 | `agents/claudehut-learner.md:16` | Prompt implies the learner's own return is gated on producing output, but its SubagentStop branch fails open when no candidates file is written. |
| AGENT-4 | `agents/claudehut-db-reviewer.md:17` | Four auditors inline near-verbatim rigor-contract prose that already lives in `references/review-rigor.md` → 4-way drift surface. |
| AGENT-5 | `agents/claudehut-explorer.md:36` | Explorer's "never mutate" is prose-only despite a full `Bash` grant (same least-privilege pattern, lower stakes). |
| AGENT-6 | `agents/claudehut-reviewer.md:7` | `effort: xhigh` frontmatter is load-bearing in the prompts but is not a documented subagent field with a verified consumer (plausible-not-confirmed). |
| SKILL-2 | `skills/implement/SKILL.md:3` | Phase skills gate triggers to "Java/Spring" while `brainstorm` declares itself stack-agnostic → ambiguous trigger selection on non-Java tasks in mixed repos. |
| SKILL-3 | `skills/write-plan/SKILL.md:3` | `write-plan` (~85w) / `discover` (~79w) descriptions pack procedural detail into the always-loaded trigger slot vs. the tighter `implement` (48w). |
| HOOK-2 | `scripts/inject-phase.sh:28` | While `phase=discover`, every UserPromptSubmit runs a recursive `find` over all of `.claude/` for an advisory-only warning — latency on repos with large `.claude/` trees. |
| HOOK-3 | `scripts/record-skill-expansion.sh:27` | Reads speculative UserPromptExpansion fields; if the real event omits them, the slash-invocation rail fails closed (denies writes until manual `mark-skill`). |
| HOOK-4 | `scripts/inject-phase.sh:14` | Empty `session_id` → state path `state/.json` never exists → silently re-anchors an in-flight task to `discover` in injected context. |
| HOOK-5 | `scripts/harvest-candidates.sh:35` | `grep -cF` on a derived signature counts lines, not records; a short signature can over-count and emit a spurious "recurring" candidate (dropped later by the quality gate). |
| UX-3 | `scripts/inject-learnings.sh:55` | Injected learnings are count-bounded (`--top 5`) but not byte-bounded per entry; a verbose learning taxes every turn for ~30d with only a prose "one sentence" convention as guard. |
| ARCH-2 | `.claude-plugin/plugin.json:16` | `defaultEnabled: true` cannot be verified against the manifest spec from local files (remote-only `$schema`); harmless if ignored, could fail strict validation. |
| EVAL-3 | `.github/workflows/ci.yml:53` | `for f in scripts/*.sh bin/*` — an empty/renamed `bin/` makes the exec-bit check glob to a literal and either error or silently skip. |

---

## 3. Upgrade roadmap

Every item traces to finding IDs. Effort is rough dev-time.

### Quick wins (< 1 day each)

| Item | Resolves | What / why | Effort |
|------|----------|------------|--------|
| **Gitignore `state/` + drop secrets from failure capture** | SEC-2 | Make `claudehut-init` write `.claude/claudehut/state/` (and `*.failures.jsonl`) into the target project's `.gitignore`; redact obvious secret patterns (`Bearer …`, `PASSWORD=`, `AWS_SECRET…`) before persisting in `record-failure.sh`; change the closing message from "Commit `.claude/`" to explicitly exclude `state/`. Highest real-risk item. | ~0.5d |
| **Fix `plan_hash` fallback** | HOOK-1 | Test `shasum`'s exit code (or `command -v shasum`) instead of relying on the awk pipeline; fall through to `cksum`/`sha256sum`. Restores the anti-tamper guard on minimal hosts. | ~1h |
| **Correct README agent count + roster** | ARCH-1 | "12 specialists" and add `claudehut-plan-reviewer`. | ~15m |
| **Tighten the length-linter PROV regex** | UX-2 | Add `WS-[0-9]`, bare `Issue [0-9]`, `v0\.[0-9]` to the pattern; re-run against bodies and clean what it now flags. | ~1h |
| **Least-privilege the read-only auditors** | AGENT-2, AGENT-5 | Drop `Bash` from `reviewer`/`perf-reviewer`/`security-auditor`/`explorer` (match `db-reviewer`), or give a read-only Bash allowlist. Makes the read-only contract tool-enforced, not prose. | ~0.5d |
| **Mermaid presence guard in CI** | EVAL-1 | One assertion: every `agents/*.md` + `skills/*/SKILL.md` that shipped a ```mermaid fence still has a non-empty one (optionally pipe through a mermaid validator). Catches accidental deletion/corruption. | ~2h |
| **Harden the CI exec-bit glob** | EVAL-3 | Quote + null-guard the `bin/*` glob (`shopt -s nullglob` or `[ -e "$f" ]`). | ~15m |

### Structural (multi-day)

| Item | Resolves | What / why | Effort |
|------|----------|------------|--------|
| **Lock the global learning store** | MEM-1 | Wrap `merge-learnings.sh`'s read-modify-write in an advisory lock (`flock` on a `.lock`, or a lockfile with `mkdir` for portability) so concurrent Learn passes serialize instead of clobbering. Alternative: make writes append-only + a separate compaction pass. | 1–2d |
| **Prune/compact + supersede in the memory engine** | MEM-2, MEM-3, MEM-4 | Add age/relevance decay that can retire even reinforced entries (cap store size / TTL on `hits`); make rule-file promotion idempotent and removable (regenerate promoted blocks from the store rather than `>>`-append); reset `recurrence` when an entry goes quiet for N sessions. Turns the RL loop from monotonic-growth into a genuine feedback system. | 2–3d |
| **Sanitize learning content before persist + inject** | SEC-1 | Strip/escape directive-looking text and URLs in `harvest-candidates.sh`/`merge-learnings.sh` before storing; treat injected learnings as data (fenced, labeled "untrusted note") in `inject-learnings.sh`. Closes the stored-prompt-injection chain. | 1–2d |
| **Enforceable subagent contracts** | AGENT-1, AGENT-3 | Either make `verify-subagent.sh` block the *never-wrote* case (require the artifact unconditionally for dispatched plan-reviewer/learner, with the existing consecutive-Stop cap as the anti-wedge), or soften the prompts to state the real (fail-open) guarantee. Align prompt claims with actual enforcement. | 1d |
| **Extend the gate-unit matrix to the profile rail** | EVAL-2 | Add `gate-tests.sh` cases for `profile=audit/investigation`: findings-path required, audit-is-engagement fail-open, learn-receipt-on-non-trivial, plus the new park-and-wait fail-open by name. | 1d |

### Strategic (v0.9+ direction)

- **Move enforcement from prose to tool-scoping wherever possible** (AGENT-2/3/5, AGENT-1). The recurring
  theme across dimensions 2 & 6 is *the prompt asserts a guarantee the harness doesn't enforce*. A v0.9
  principle — "every 'read-only'/'must produce X' claim is backed by a tool grant or a hook, never by prose
  alone" — would systematically close this class.
- **Treat the memory store as an adversarial input surface** (SEC-1 + MEM-*). The learning engine is the
  plugin's most novel asset and its least-defended one: it persists model/tool-derived text and re-injects it
  into future context. A first-class trust boundary (sanitize on ingest, label on inject, bound growth,
  supersede on rule files) is the highest-leverage strategic investment.
- **Stack-agnostic core, Java/Spring as a profile** (SKILL-2). The workflow spine is generic but the phase
  skills advertise Java/Spring; formalizing the split (generic phases + a swappable stack pack) widens the
  plugin's reach without touching the enforcement engine.
- **A "self-audit" eval** (EVAL-1/2, UX-2, ARCH-1). Several findings are *the plugin failing to check
  itself* (linter misses its own tags, diagrams uncovered, README count drifts). A cheap conformance pass
  that asserts internal consistency (doc counts == directory, linter catches its own targets, every shipped
  diagram covered) would keep this class from recurring.

---

## 4. Verify pass & the refuted findings

The adversarial layer changed the picture materially:

- **SKILL-1 (first-pass High) — REFUTED.** Claim: skills invoke bare `claudehut-state` but `bin/` is never
  on `PATH`, so every state write hits command-not-found and the write gate denies all production writes.
  **Reality:** the official Claude Code plugin docs state *"`bin/` — Executables added to the Bash tool's
  `PATH`… invokable as bare commands in any Bash tool call while the plugin is enabled."* The bare form is
  the **documented idiomatic pattern**, not a bug. Corroborated by primary evidence: the v0.8 live benchmark
  ran the full 7-phase workflow to completion (state recorded live), which is only possible if the bare
  command resolves. Both auditors had explicitly flagged this as their one "unverifiable external fact."
- **UX-1 (first-pass High → Medium → REFUTED).** Same root cause: the gate deny messages tell the agent to
  run bare `claudehut-state …`. Because `bin/` is on `PATH`, those messages are **correct and actionable** as
  written. Not a defect.
- **MEM-1, SEC-1, EVAL-1 — confirmed real but downgraded to Medium** with the reasoning captured in the
  findings table (race window is narrow; the injection store is git-ignored + promotion-gated; the diagrams
  are non-executable). The verifier CONFIRMED MEM-1's and EVAL-1's mechanisms exactly and only adjusted
  blast radius.

Net: the audit's *first-pass* severities over-weighted an incorrect assumption about plugin runtime. The
verified picture is a healthy plugin whose real work is hardening the memory engine and secret hygiene.

---

## 5. Verdict — top 3 highest-leverage changes

1. **Close the secret-leak path (SEC-2).** Auto-gitignore the target project's `state/`, redact secrets in
   `record-failure.sh`, and fix the "commit `.claude/`" guidance. It is the only finding with a direct,
   realistic path to leaking live credentials into version control — highest real-world risk, lowest effort.
2. **Make the memory engine safe and self-limiting (MEM-1/2/3/4 + SEC-1).** Add locking, pruning/compaction,
   removable rule promotion, recurrence reset, and ingest sanitization. This subsystem is the plugin's
   differentiator and its weakest link; today it can lose data, grow unbounded, carry stale rules forever, and
   persist unsanitized text into future prompts.
3. **Back every prompt guarantee with enforcement, and cover the profile rail in tests (AGENT-1/2/3/5 +
   EVAL-2).** Drop `Bash` from the read-only auditors, make the "must produce an artifact" contracts actually
   block (or stop advertising them), and extend `gate-tests.sh` to the audit/investigation completion path.
   Turns prose promises into verified invariants — exactly the plugin's own design philosophy.

---

## Appendix A — Files read (coverage evidence)

**Agents — all 12 read** (note: the repo has **12** agent files, not 13; the README's "11" is finding
ARCH-1): `claudehut-brainstormer`, `claudehut-db-reviewer`, `claudehut-explorer`, `claudehut-implementer`,
`claudehut-learner`, `claudehut-perf-reviewer`, `claudehut-plan-reviewer`, `claudehut-planner`,
`claudehut-reuse-scanner`, `claudehut-reviewer`, `claudehut-security-auditor`, `claudehut-test-runner`.

**Skills — all 9 SKILL.md read** (+ selected `references/`): `brainstorm`, `capture-learnings`,
`claudehut-init`, `claudehut-workflow`, `discover`, `implement`, `review`, `write-plan`, `write-spec`.

**Hook scripts — all 17 read:** `bootstrap`, `format-java`, `gate-done`, `gate-write`, `harvest-candidates`,
`inject-learnings`, `inject-phase`, `learning-score`, `lint-prompt-length`, `lint-reuse`, `load-probe`,
`merge-learnings`, `persist-state`, `record-failure`, `record-skill-expansion`, `record-skill`,
`verify-subagent` — plus `hooks/hooks.json`.

**Bin executables — all 4 read:** `claudehut-init`, `claudehut-state`, `claudehut-worktree`, `kafka-mcp`.

**Manifests & config:** `.claude-plugin/plugin.json`, `marketplace.json`, `README.md`,
`.github/workflows/ci.yml`, `.claude/docs/design/09-plugin-structure.md`.

**Evals:** `run.sh`, `conformance.sh`, `gate-tests.sh`, `merge-learnings-tests.sh`,
`artifact-oracle-tests.sh`, `llm-judge.sh`, `score.sh`, `evals/tasks/`, `evals/judge/`.

## Appendix B — Method & caveats

- 8 dimension auditors (read-only) → per-dimension adversarial verification of every Critical/High finding →
  synthesis (dedup, cross-reference, re-rank) by the main thread. No plugin file was modified; no repo script
  or eval was executed.
- The one external fact the read-only audit could not settle (`bin/`-on-`PATH`) was resolved against the
  official Claude Code plugin docs, which **refuted** the two highest first-pass findings (§4).
- `ARCH-2` (`defaultEnabled`) remains spec-unverifiable from local files; the docs confirm `bin/` is a valid
  default location requiring no manifest field, but did not address `defaultEnabled` specifically.
