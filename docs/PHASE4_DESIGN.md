# Phase 4 — Memory & Retrieval Reinforcement: best-practice implementation spec

> Source: a 12-agent design workflow (5-dimension research sweep → 3 independent
> proposals → adversarial judging → synthesis). Chosen base = Proposal 3 +
> 6 blocking fixes from the adversarial judges. This doc is the implementation
> contract; every item ships a deterministic, CI-testable proving test.

## Goal

Replace the static **head-200 "Recent learnings" dump** (`dispatch-prompt.sh:~70`)
with (4.1) **JIT relevance retrieval** of the top-k learnings relevant to *this*
task, ranked by (4.3) an **outcome-signal usefulness prior**. 4.6 = the honest
rename (this is **Memory & Retrieval Reinforcement**, a success-recurrence prior —
NOT reinforcement learning).

## Why not the obvious choices (decided by research + adversarial judging)

- **No BM25/TF-IDF.** Corpus is N~20–200 entries/project; IDF is statistically
  unstable at that size — adding 2–3 entries reshuffles rankings, which **breaks
  the CI proving test's exact-order assertions**. Use intrinsic-ratio (Jaccard)
  scoring, stable as the corpus grows.
- **No memory MCP.** `dispatch-prompt.sh` is bash; MCP retrieval needs a live model
  mid-turn → a model-free CI test is architecturally impossible. The declared
  `@modelcontextprotocol/server-memory` is vestigial; not touched.
- **No sha256 sidecar key.** jq 1.6 has no `sha256` builtin → keying by a derived
  sig would fork `shasum` per entry (~10ms × N) in the dispatch hot path. Key by
  the plain string `lower(title):category` (pure jq, zero forks).

## 4.1 — Retrieval (`skills/learn/scripts/retrieve-relevant.sh`)

Args: `PROJECT_ROOT USER_INTENT TASK_ID [K=5]`.

**Query construction** (bash 3.2 + POSIX awk; path extraction via `split($0,a,"\`")`
NOT 3-arg `match()` — `bash-compat.sh:52`; lowercase via `tr` not `${var,,}` —
`bash-compat.sh:48`):
- `plan_pkgs` = dirname of each `- (create|modify|test): \`path\`` in
  `.claudehut/plans/<task_id>-plan.md` (empty set when plan absent).
- `stack_tags` = non-`none` values from `.claudehut/memory/stack-signals.md`
  (direct awk parse over `- key: value`, not a per-key `claudehut_stack_signal` loop).
- `intent_tokens` = lowercase alphanumeric tokens of USER_INTENT, stopword-filtered
  (`a an the in of to for and or with add create update implement using via from on by at`).
- `Q_tags` = `intent_tokens ∪ stack_tags`; `Q_title` = `intent_tokens ∪ {basename(plan paths)}`.

**Per-entry score** (skip tombstone/deprecated + `replaces`-superseded entries):
```
S_path  = |pkg(L.files_touched) ∩ plan_pkgs| / max(|plan_pkgs|,1)     # 0 when no plan (not an error)
S_tag   = |L.tags ∩ Q_tags|   / max(|L.tags ∪ Q_tags|,1)              # Jaccard
S_title = |terms(L.title) ∩ Q_title| / max(|terms(L.title)|,1)
R       = 0.45*S_path + 0.30*S_tag + 0.10*S_title                     # relevance subtotal
# FLOOR on R (before prior): discard if R <= 0.05  — a cold entry at zero relevance
#   (S_prior 0.5 → 0.075) must not surface. brainstorm/spec (S_path=0) need real tag/title overlap.
S_prior = (useful+1)/(used+2)   from usefulness.json[lower(title):category]  # Laplace, cold=0.5
score   = R + 0.15*S_prior      # only for entries with R > 0.05
```
**Selection:** sort `score DESC → S_prior DESC → ts DESC → task_id ASC → title ASC`
(5-level, fully deterministic on a fixed fixture). Emit `min(K, count_above_floor)`
markdown bullets under `## Relevant learnings`; `(none yet — finish a task to populate)`
when empty.

**Self-degrading (protects `set -e` dispatch callers):** internal
`trap '…stub…; exit 0' ERR` — malformed JSONL, missing dirs, jq errors all emit the
stub and exit 0. The script **never** exits non-zero.

**Retrieval log (append, not overwrite):** append one line
`{"task_id","ts","sigs":[...]}` to `.claudehut/state/retrieval-<task_id>.json`. All 6
phases write the same file; `update-usefulness.sh` unions+dedups `sigs` at read time
(correct attribution — overwrite would credit the *learn* dispatch, not *build*).

## 4.3 — Usefulness prior (`skills/learn/scripts/update-usefulness.sh`)

Args: `TASK_ID`. Storage: `.claudehut/memory/usefulness.json` =
`{ "lower(title):category": {used,useful} }`, atomic `jq → tmp → mv` (promote.sh pattern).

1. Idempotency: exit 0 if `.claudehut/state/usefulness-scored-<task_id>.marker` exists.
2. Read+dedup sigs from the retrieval log (`jq -s '[.[]|.sigs[]]|unique'`); absent → exit 0.
3. `decision` from `findings/<task_id>-findings.json`; empty → exit 0.
4. Per sig: `used += 1`; `useful += 1` iff `decision=="pass"`.
5. Write atomically; write the marker.

**Honesty (judge-corrected):** in v1 `update-usefulness.sh` is called only from the
**pass-gated** learn pipeline (`state.sh` → learn only on pass), so `decision` is
always `pass` → it is a **success-recurrence prior** (retrieved-into-passing-tasks
rank higher), monotone-up. The `fail` branch is wired + proven (test case 7) but
unreachable until a non-pass callsite exists = **the 4.4 seam** (documented deferred
work, not dead code). Downward pressure in v1 = the Laplace denominator only.

## Substrate

JSONL corpus (unchanged) + `usefulness.json` (mutable sidecar) + per-task
`retrieval-<task>.json` (append) + `usefulness-scored-<task>.marker`. Zero new deps.
`learnings-recent.md` + `regenerate-recent.sh` + the CLAUDE.md `@import` are the
**ambient recency channel** — unchanged. The JIT section is a curated ranked
highlight, not a replacement for the ambient channel.

## File plan (ordered)

1. `skills/learn/scripts/retrieve-relevant.sh` — NEW (ranker, self-degrading, logs).
2. `skills/learn/scripts/update-usefulness.sh` — NEW (sidecar updater, idempotent).
3. `tests/fixtures/learnings-sample.jsonl` — NEW (9 entries: 3 mapstruct, 2 flyway,
   rest, kafka, generic, +1 tombstone; two mapstruct tie on R for the S_prior test).
4. `tests/fixtures/usefulness-sample.json` — NEW (entry A used=10,useful=9→0.833;
   B used=10,useful=1→0.167).
5. `tests/integration/retrieve-relevant-test.sh` — NEW (11 cases, no model calls).
6. `tests/run-all.sh` — add section **L19** (last section is L18) invoking the test.
7. `skills/{brainstorm,spec,plan,verify-review,learn}/scripts/dispatch-prompt.sh` — one-line
   swap (line ~60): `emit_section "Recent learnings" …` → `bash "$PLUGIN_ROOT/skills/learn/scripts/retrieve-relevant.sh" "$PROJECT_ROOT" "$USER_PROMPT" "$TASK_ID" || true`; comment `5. Recent`→`5. Relevant`.
8. `skills/build/scripts/dispatch-prompt.sh` — same swap (line ~70; comment line 16).
9. `agents/claudehut-learner.md` — add `update-usefulness.sh <TASK_ID>` as the final
   learn-pipeline step (Tools + Output contract).

> DRY note: a shared `hooks/lib/emit-learnings.sh` helper was **deferred** — each
> dispatch-prompt.sh must still be touched (per-phase context), so the helper adds a
> file without removing edits. 6 surgical one-liners are the minimal change.

## Proving tests (`tests/integration/retrieve-relevant-test.sh`, 11 cases, < 2s, sandboxed)

1. Exact ranked order (path+tag dominant); tombstone + below-floor entries absent.
2. Deterministic tiebreak (run twice → byte-identical).
3. Absent plan → S_path=0, degrades, still ranks by tag/title.
4. Absent learnings.jsonl → stub + exit 0.
5. Retrieval log written as appended JSON line(s) with `sigs`.
6. `update-usefulness` pass credit → used=1,useful=1 + marker.
7. `update-usefulness` fail-path → used=1,useful=0 (S_prior=0.333<0.5; proves 4.4 seam wired).
8. Idempotency → second run no-ops.
9. Absent retrieval log → exit 0, sidecar untouched.
10. Malformed learnings.jsonl → exit 0 + heading (self-degrading).
11. **S_prior sole discriminant** (mandatory, Judge 3): two entries identical on
    R, differing usefulness → higher-useful outranks. Without this a build with
    `S_prior` weight=0 passes all other cases.

## Deferred (out of Phase-4 MVP)

- **4.2** MCP integration (untestable in bash; vestigial).
- **4.4** fail-path usefulness signal (branch wired+tested; needs a non-pass callsite).
- **4.5** meta-learning / cross-project promotion via usefulness.
- Retrieval-log pruning; explicit decay (γ); `emit-learnings.sh` shared helper.

## Open questions (resolve before/at implementation)

- **4.6 = the docs rename** ("Reinforcement Learning" → "Memory & Retrieval
  Reinforcement"), per UPGRADE_PLAN. The workflow's "feedback-capture" reading is
  subsumed by 4.3. Confirmed: 4.6 is the rename.
- Should the **learn-phase** dispatch keep ambient `learnings-recent.md` instead of
  JIT (the learner mines the diff, doesn't consume guidance)? Low harm either way.
- `K=5` default for all phases (build maybe 7, brainstorm maybe 3) — K is an optional
  arg; per-phase overrides are one-line later.
