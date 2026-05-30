# Phase 6 + 7 — right-sized best-practice plan (NOW vs DEFER)

> Source: a 12-agent design workflow (research → proposals → adversarial judging →
> synthesis). The roadmap's north star governs every call: **"smaller, measured,
> adaptive — not larger."** A well-argued DEFER is a success, not a gap. Every NOW
> item ships a deterministic, model-free proving test and extends the 458-test arc.

## Verdict

The remaining phases are mostly **already solved or strategically premature**. The
genuinely high-leverage, low-risk work is small. Implement it NOW; defer the
big-bang items behind explicit eval-gated triggers.

## NOW (implement — surgical, falsifiable)

### 6.1 — close the rules-layer gap (NOT `paths:` on skills)
`paths:` is a **rules** feature, not a skills feature — all 31 `SKILL.md` are
name+description per spec (L1.4), and the `rules/**/*.md` + `init-project.sh`
stack-filtered copy **already is** the path-activation mechanism (90% done). The
only real gap: kafka has mirror rules, **nats/rabbitmq do not**.
- **6.1a** CREATE `rules/framework/nats.md` — mirror `kafka-consumer.md` EXACTLY
  (block-style `paths:` with `  - "glob"` items — L1.7 line 199 greps `^[[:space:]]+- `,
  so an inline `[...]` array would FAIL; double-quoted `stack:`). Globs
  `**/*NatsListener*.java` + `**/*NatsClient*.java`, `stack: "messaging=nats"`.
- **6.1b** CREATE `rules/framework/rabbitmq.md` — same, glob `**/*RabbitListener*.java`,
  `stack: "messaging=rabbitmq"`.
- **6.1c** `tests/run-all.sh` L4 rule-count `45 → 47` (+ annotation) — ATOMIC with 6.1a/b.
- **6.1d** CREATE `tests/static/path-skill-map.sh` (L1.9): a bash-3.2 path→rule
  resolver that **extracts globs at runtime** (awk, not hardcoded) + `[[ path == $glob ]]`
  matches **full-path** fixtures (bare basenames don't exercise `**/`; bash `[[ ]]`
  has no globstar so `*` spans `/` — broader than the loader's minimatch, fine for
  presence/gap). MUST run under real bash (the Bash tool runs zsh, which treats an
  expanded `$glob` literally → use `bash …`). Fixtures: `src/…/OrderNatsListener.java`
  → nats (RED before 6.1a); `src/…/PaymentController.java` → NO messaging rule
  (do NOT assert "nats≠kafka" at glob level — kafka carries `*Listener*` too, the
  separation is init's stack-filter); `src/…/db/migration/V…__….sql` → flyway-naming.

### 6.2 — DRY the builder guardrails via a FLOOR-SUBSET invariant (not equality)
The guardrails live in two places (`run-parallel-group.sh` GUARDRAILS heredoc +
`agents/claudehut-builder.md`) and have **drifted with intentionally-different
content**. Byte-equality is the WRONG invariant; **Option A (persona-derive the
heredoc) is rejected** — the heredoc is the unconditional safety floor for when
`--agent` resolution fails, so deriving it means a heading rename silently drops
all guardrails (a safety failure worse than drift).
- **6.2a** ADD `tests/run-all.sh` L23 — three `grep -Fq` floor-subset assertions:
  the phrases `NEVER execute more than ONE task`, `claudehut-builder-result`,
  `failing test` must appear verbatim in **both** files (all green on current state;
  RED if either drops one — catches drift both directions). Heredoc-only rules
  (SURGICAL SCOPE, `git add` guard, ONE commit) are deliberately NOT in the floor.
- **6.2b** `run-parallel-group.sh` comment: "Keep in sync" → "Floor phrases
  validated by L23" (removes the manual sync obligation).

### 7.1-now — make the SDK "parity at lower variance" gate EXECUTABLE
The one 7.1 item with a deterministic test (and the precondition for any future
SDK decision): instrument variance.
- `evals/compare.sh` — add a `--variance <results.jsonl>` mode: per-task/mode
  mean+variance of pass@1/cost/wall (pure awk: `E[x²]−E[x]²`). `run.sh` unchanged
  (the `-k` collection loop is model-gated, deferred).
- `tests/run-all.sh` L17 extension — synthetic k=3 fixture (pass@1 [1,0,1], cost
  [1.0,1.5,2.0]) → assert `mean_pass≈0.67`, `var_cost>0`. Fails before (no flag).

## DEFER (with concrete go/no-go triggers)

- **6.1 1%-rule relaxation** — the only test is cosmetic grep (proves the edit, not
  that agents over-invoke less); 18-carrier churn, zero behavioral signal. **Trigger:**
  a Phase-2 eval task (Controller-only Files block) that fires `kafka-consumer`
  today → measured baseline → relax across all 17 carriers → measure the delta.
- **6.1 trim descriptions** — no measured context cost. **Trigger:** eval shows
  description-length overhead.
- **6.3 modularize (4 sub-plugins)** — DEFER indefinitely: selectivity already
  solved (rules + stack-filter); the taxonomy doesn't partition (jackson/lombok/
  mapstruct/testcontainers/wiremock are cross-cutting); `run-all.sh` has hardcoded
  counts + `find skills/` globs → a full harness rewrite; larger on every axis,
  zero demand. **Trigger:** a 2nd contributor needs a separate release cadence AND
  asks, OR skills cross ~50 AND eval shows overhead the stack-filter can't fix.
- **6.4 context:fork dispatch** — DEFER, eval-gated: #49559/#17283 status is
  unverifiable vs the pinned CC version; current dispatch is tested (L12/L16).
  **Trigger (in order):** confirm the issue resolved in the pinned version's
  changelog → port ONE phase (route) → eval parity → no L12/L16 regression.
- **7.1 Agent SDK re-platform** — DEFER behind 3 ordered preconditions: (1) pass@k
  variance instrumented (the 7.1-now item) + k≥3 runs collected → the parity gate
  becomes executable; (2) an `allowedTools`+`permissionMode`-per-persona mapping
  spike (the SDK ignores SKILL `allowed-tools`); (3) SDK billing-pool separation
  evaluated. Violates "SMALLER" until all three clear.

## Open questions
- The pinned Claude Code version (for the 6.4 #49559 check).
- The 7.1 `allowedTools` mapping spike (16 personas).
- `run.sh -k` pass@k collection (model-gated; a future micro-phase or folded into the 7.1 trigger).
