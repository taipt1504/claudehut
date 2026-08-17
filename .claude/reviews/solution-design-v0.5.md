# Solution Design v0.5 — Review rigor + reasoning depth (APPROVED & EXECUTED — see §Verification)

Sources: 4 cited research/audit agents (claude-code-guide native verification · official Anthropic review/thinking docs · top-plugin review enforcement · in-repo review root-cause). `advisor` tool is NOT in this environment → substituting an adversarial critique pass before commit (flagged, same as v0.4).

---

## Environment blocker (verified — decide first)

`~/.claude/settings.json` (user-global, **outside this repo**) sets:
- `CLAUDE_CODE_SUBAGENT_MODEL=sonnet` → **overrides every subagent `model:` frontmatter** [sub-agents.md: env var is highest precedence]. `model: opus` on planner/brainstormer/security-auditor is **already inert**; the requested implementer→opus will not take effect here until this changes.
- `CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING=1` → switches **Sonnet** from adaptive reasoning to a fixed budget (`MAX_THINKING_TOKENS`); with it set and `MAX_THINKING_TOKENS` unset, `effort` no longer drives Sonnet thinking. **Opus 4.7+/4.8 are always adaptive and ignore the flag — `effort` works on the opus agents regardless** [model-config.md].

**The plugin-side fix (frontmatter `model`/`effort`) is correct and portable** — it works for any installer who hasn't set those overrides. But on THIS machine the env wins. Editing `~/.claude/settings.json` is out-of-repo → needs explicit OK (Q1).

---

## Part 1 — Reasoning-depth config (the user's two direct asks)

| Agent | Now | → | Rationale |
|---|---|---|---|
| `claudehut-implementer` | sonnet, no effort | **opus, effort: xhigh** | user ask; deepest reasoning while writing code |
| all 11 agents | mixed/none | **effort: xhigh default** | user ask; `xhigh` falls back to `high` on sonnet 4.6 (still raises depth) |

Native lever: `effort` frontmatter (`model-config.md`). Mechanical agents (test-runner, reuse-scanner, explorer, learner) gain little from xhigh and cost more latency — flagged, but applied per the explicit "default xhigh for all" directive unless you say otherwise (Q2).

Design sync: `.claude/docs/design/03-agents.md` (per-agent model/effort table).

---

## Part 2 — Review-phase rigor (root-caused, RC-1..RC-7)

**Measured problem (audit, file:line cited):** 4/5 auditors run `sonnet` with no `effort` and no deep-think directive — they have *less* thinking budget than the brainstormer (opus+xhigh); any auditor can return a bare `PASS` with zero cited evidence; enforcement-set items are never ticked one-by-one (silent skips look like passes); `set-review pass` is a self-asserted flag no gate validates; learnings/pitfalls don't reach auditors; no severity rubric or defect-class floor; perf-reviewer is opt-in with no call-chain trace floor.

**Research grounding (cited):** fresh-context adversarial review + "report gaps not style", evidence-per-finding ("behavioral claims need a file:line citation, not inference from naming" — official code-review REVIEW.md), rubric-guided review (ACM ICER 2025), refute-don't-confirm + strip authorship (confirmation-bias papers), `ultrathink` is the ONLY recognized deep-think keyword (`think hard` is plain text — model-config.md), sequential spec→quality + mandatory re-review loops + post-review validation pass (superpowers, feature-dev, code-review plugins).

### Fixes (each native; design↔impl in sync)

| # | Fix (root cause) | Mechanism (native) | Files |
|---|---|---|---|
| **A** | Reviewer depth (RC-1) | `claudehut-reviewer`/`perf`/`db` → **opus + effort xhigh**; security-auditor (already opus) → +xhigh; add literal **`ultrathink`** directive to each auditor body (only recognized keyword); test-runner stays sonnet (mechanical) | agents/claudehut-{reviewer,perf-reviewer,db-reviewer,security-auditor}.md |
| **B** | Evidence-cited coverage table (RC-2, RC-3) | New output contract: **one row per enforcement-set item + per mandatory defect class** → `satisfied/violated/n-a` + `file:line` + quoted code. **PASS forbidden unless every row is satisfied/n-a WITH evidence.** Ban bare "looks good/PASS". Verification bar verbatim from official REVIEW.md pattern. | all 4 auditor agents; skills/review/SKILL.md |
| **C** | Shared severity rubric + defect floor (RC-6) | One scale in review skill + every auditor: **CRITICAL/HIGH block · MED blocks-unless-justified · LOW advisory**; each auditor must attest EACH defect class in its floor (e.g. perf: N+1, fetch strategy, index, blocking-in-reactive, allocation) even when clean | skills/review/SKILL.md; 4 auditors |
| **D** | Refute-framing, strip authorship (RC-2) | Senior-engineer role + stakes; "assume unproven; confirm each invariant with cited evidence; report gaps affecting correctness/requirements, not style". Do NOT use "find ≥N" (manufactures findings) or over-prescriptive steps (raises misjudgment — verification-failures paper) | 4 auditors |
| **E** | `set-review pass` earns it (RC-4) | `claudehut-state set-review pass` gains **`--evidence <review.md>`**; validates the file exists + contains a filled coverage table + a fresh test-run summary (mirrors existing `tmpl()` spec/plan validation). `gate-done.sh` already checks `review==pass`; now pass is no longer free. | bin/claudehut-state; skills/review/SKILL.md; scripts/gate-done.sh (doc only) |
| **F** | Memory reaches auditors (RC-5) | review SKILL adds to the MUST-carry dispatch list: prompt-filtered learnings (`inject-learnings.sh --filter <changed-files+enforcement keywords>`) pasted per auditor; auditors instructed that path-scoped rules auto-load when they Read changed files (promoted pitfalls included) | skills/review/SKILL.md; 4 auditors |
| **G** | Post-review validation pass (RC-2, RC-4) | After the parallel auditors return, **one validation step refutes each blocking finding AND each PASS attestation** (cheap; sonnet) — false positives dropped, unproven passes bounced back. Lighter than a full judge panel; matches official code-review validation gate. | skills/review/SKILL.md |
| **H** | Perf-reviewer coverage (RC-7) | Required **call-chain trace floor** (every finder→loop, every collection iterated post-finder, every Mono/Flux for `.block()`); tighten dispatch so any repository/loop/reactive/entity touch includes it (drop "safe to skip" bias) | agents/claudehut-perf-reviewer.md; skills/review/SKILL.md |

Design sync: `01-agentic-workflow.md` §8 (review loop + earned-pass exit), `03-agents.md`, `06-hooks.md` (set-review evidence note).

### Verification
- Deterministic: extend `evals/gate-tests.sh` — `set-review pass` without/with valid `--evidence`; conformance for new model/effort frontmatter; review.md coverage-table presence.
- Live (if run): a seeded-defect task (plant an N+1 + a missing `@Valid`) → review must catch both and block; compare against pre-change baseline. Mark `[not verified]` with reason if not run.

---

## Decisions (resolved)
1. Env-var blocker → **fix plugin frontmatter AND global env**. Removed `CLAUDE_CODE_SUBAGENT_MODEL` + `CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING` from `~/.claude/settings.json` (backed up to `settings.json.bak-*`). **Blast radius:** affects ALL the user's projects — every subagent now uses its own frontmatter model (claudehut's: opus for reasoning agents, sonnet for mechanical) instead of being forced to sonnet, and adaptive thinking is re-enabled globally. Revert = restore the backup. Takes effect on the next CC session (current shell keeps old env).
2. Effort `xhigh` on mechanical agents → **applied to all 11** per directive (xhigh→high on sonnet; modest gain, accepted for uniformity).
3. Reviewer tier → **all 3 code reviewers (reviewer/perf/db) → opus + xhigh** (max rigor).

---

# Verification (post-execution)

- **Config:** all 11 agents `effort: xhigh`; implementer + reviewer + perf + db + brainstormer + planner + security-auditor → `opus`; explorer/reuse-scanner/test-runner/learner → `sonnet`. Verified by frontmatter dump.
- **Review rigor:** 4 code-review auditors carry `ultrathink` + refute framing + coverage-table contract + shared severity scale + defect-class floor (perf has the call-chain trace floor); test-runner explicitly exempt (evidence-gatherer, no coverage table). Review SKILL adds the validation pass + learnings-into-dispatch + earned-pass.
- **Earned-pass gate:** `claudehut-state set-review pass` requires `--evidence review.md` that contains a **markdown table row** with a status token AND a real test command/count — prose containing "satisfied"/"passing" is rejected (bypass closed after the critique pass found it).
- **Deterministic suites:** `gate-tests` **71/71** (incl. 6 earned-pass cases + prose-bypass rejection), `conformance` **83/83**, `ranker` **8/8**.
- **Adversarial critique (advisor substitute — `advisor` tool absent in this environment):** 2-lens panel found 2 BLOCKERs (over-scoped "every auditor" claim sweeping in the sonnet test-runner; imprecise DISABLE_ADAPTIVE_THINKING wording) + a prose-bypass false-accept in the gate greps — all fixed and re-verified.
- **[not verified live]:** a seeded-defect end-to-end review run (plant an N+1 + missing `@Valid`, confirm review blocks). Reason: not executed this session; the gate/contract logic is covered deterministically, and the model/effort levers only take effect on a fresh CC session after the env change. Recommend one live `evals/run.sh` seeded-defect run next session to close this.
