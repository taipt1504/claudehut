# Phase 5 — Cost caps + telemetry + model-tier: best-practice implementation spec

> Source: a 12-agent design workflow (5-dim research → 3 proposals → adversarial
> judging → synthesis). Chosen base = Proposal #3 (only one with honesty=9) +
> grafts + all judge fixes. Implementation contract; every item ships a
> deterministic, model-free proving test.

## Honest framing (the budget-death reframe — load-bearing)

Every full claudehut run this project attempted budget-censored mid-pipeline. The
~$1 death was the **orchestrator MAIN SESSION** (ceremony: spec/plan/verify via
in-process `Task()` subagents), **NOT** build workers. `run-parallel-group.sh`
**cannot** see main-session spend (it's in the orchestrator's `total_cost_usd`,
known only when that session ends). So:
- The real levers against **main-session** censoring: quick routing (Phase 3),
  cheap worker models (5.3), and the top-level `--max-budget-usd` **already in
  `evals/run.sh`** (default $2). A production entrypoint should add the same cap
  (open question — none found outside evals/).
- Phase 5.1 ships a **build-phase worker-pool spend gate**, NOT a "global cap":
  it prevents launching worker groups that can't afford to complete + fixes the
  telemetry undercount. It does not protect the main session. Framed accordingly.

## Where cost lives (the double-count discriminator)

Exactly **two** sites dispatch headless `claude --print` whose cost is NOT in the
orchestrator's main-session `total_cost_usd`: `run-parallel-group.sh:174` (N
parallel build workers — primary undercount) and `scaffold-stubs.sh:107`
(sequential stub generator). **Everything else** (brainstorm/spec/plan/verify/
reviewers/learn) is in-process `Task()` → already in `total_cost_usd`. Writing
`.cost` for those would **double-count**. So only those two sites emit `.cost`.
`evals/score.sh` already sums `*.cost` → **zero logic change** (comment-only).

## 5.2 — Per-phase telemetry

**ATOMIC change to `run-parallel-group.sh` (must ship as ONE commit — partial =
every task silently FAILs):**
1. **Stream split** — line 179 `> "$OUT_FILE" 2>&1` → stdout (JSON) `> "$OUT_FILE.json"`, stderr `2> "$OUT_FILE.log"`. (`--output-format json` merged with stderr corrupts the JSON.)
2. Add `--output-format json` to the worker `claude` call.
3. **jq-before-awk** — in the single-threaded collection loop, BEFORE the existing
   `claudehut-builder-result` awk: `RESULT_TEXT="$(jq -r '.result // empty' "$OUT_FILE.json" 2>/dev/null||true)"`, then feed `printf '%s' "$RESULT_TEXT" | awk …` (awk logic UNCHANGED — only its input source changes). The result block rides inside `.result` as an escaped string; the `^```claudehut-builder-result` anchor only matches once recovered.

**NEW `skills/build/scripts/capture-telemetry.sh <json> <phase> <task> <model> <log-dir> [nonce]`:**
- jq-extract with `// 0` / `// "unknown"` guards (a SIGTERM/budget-killed worker emits no/partial JSON → zeros, exit 0, never crashes the orchestrator): `total_cost_usd`, `usage.{input_tokens,output_tokens,cache_read_input_tokens,cache_creation_input_tokens}`, `num_turns`, `duration_ms`, `subtype`, `is_error`.
- Write a **bare float** (`printf "%.6f"`) to `$LOG_DIR/${phase}-g${GROUP}-t${task}-p${nonce}.cost` — the exact format `score.sh:82` reads via `cat`. **Nonce = `$$` (PID)**, NOT `date +%s` (macOS BSD `date` is second-granularity, no `%N` → collisions).
- Append one JSONL row to `$LOG_DIR/run-summary.jsonl` via `jq -n`: `{phase,task,model,in_tok,out_tok,cache_read_tok,cache_write_tok,cost,num_turns,ms,terminal_status,is_error}`.
- Called in the **post-wait single-threaded collection loop** (no flock — unavailable on macOS bash 3.2). `scaffold-stubs.sh` reuses it: `phase=build task=scaffold`, final successful resp only (--resume cost semantics unresolved → marked potentially-partial).

## 5.1 — Worker-pool budget gate (skip, not kill)

**NEW `skills/build/scripts/budget-gate.sh <spent> <n_workers> <max_pool> <max_worker> <floor>`** — pure fn, POSIX awk, echoes `launch <worker_budget>` or `skip <reason>`:
```
remaining = max_pool - spent;  per_worker = remaining / n_workers
per_worker < floor  → skip      else → launch min(max_worker, per_worker)
max_pool empty/0    → launch (unlimited; backward-compat for projects with no budget.* keys)
```
In `run-parallel-group.sh`, **before** the dispatch loop (group boundary, no
workers in flight → race-free): read `budget.*` via `claudehut-state config`, sum
`$LOG_DIR/*.cost` (awk; empty→0), call the gate. On `skip` → write
`.claudehut/state/budget-breach.json {phase,group_num,spend_usd,cap_usd,tasks_unstarted,ts}`,
print a clear stderr message, **exit 3**. On `launch` → set `WORKER_BUDGET_USD`.

Per-worker flag: `--max-budget-usd "$WORKER_BUDGET_USD"` (generous backstop,
default $4 ≈ 10× median; a tight cap recreates mid-task kill). **No `--max-turns`**
(absent from the CLI; the existing `TASK_TIMEOUT` watchdog bounds wall-clock).
Budget-killed worker (`subtype=error_max_budget_usd`) → FAIL path (no pass block →
not merged; EXIT trap removes the worktree) + a distinct stderr line.

**`skills/build/SKILL.md` — wire exit 3** (else it's a no-op): group loop gains
`Exit 3 → budget halt; read .claudehut/state/budget-breach.json; surface
spend/cap/tasks_unstarted to the user; do not retry`.

**`templates/claudehut-config.template.json`** — add `"budget": {max_worker_pool_usd:8.00, max_worker_usd:4.00, worker_budget_floor:0.50}`.

## 5.3 — Model-tier wiring

**Config key is `agents.builder_model`** (NOT `phase.builder_model` — verified in
the template; wrong key silently no-ops). **NEW `skills/build/scripts/resolve-worker-model.sh <plugin_root> <main_repo>`**: three-tier — `CLAUDEHUT_WORKER_MODEL` env > `claudehut-state config agents.builder_model` > `sonnet`; a bash-3.2 `case` guard validates the id (`opus|sonnet|haiku|claude-{opus,sonnet,haiku}-4-*`) and warns+falls-back-to-sonnet on an unknown id (a bad id crashes the session launch). Replaces the hardcoded `WORKER_MODEL=` in `run-parallel-group.sh` + `scaffold-stubs.sh` (placed AFTER `PLUGIN_ROOT` is resolved).
**`reviewer_models` DEFERRED** — reviewers dispatch via in-process `Task()` which
has no per-call `--model` override; declared in the template, not consumed.

## File plan (ordered; each ships its proving test)

1. `capture-telemetry.sh` NEW — L22.1 happy-path, L22.2 killed-worker→zeros, L22.3 nonce-uniqueness, L22.8 budget-kill row.
2. `resolve-worker-model.sh` NEW — L22.4 (env>config>default, bad-id warn+fallback, **agents.* not phase.* regression guard**).
3. `budget-gate.sh` NEW — L22.5 launch, L22.6 skip + zero-cap-unlimited.
4. `run-parallel-group.sh` EDIT (the 7 atomic changes above) — L22.7 collection-loop atomicity (jq-before-awk required; raw awk on `.json` → empty STATUS, proving they ship together).
5. `scaffold-stubs.sh` EDIT (model resolve + capture-telemetry on success) — L22.9.
6. `claudehut-config.template.json` EDIT (budget.*) — L1.1 JSON validity (existing).
7. `skills/build/SKILL.md` EDIT (exit 3 + model-config doc) — L22.10 grep.
8. `evals/score.sh` EDIT (comment-only; drop the "undercounted" disclaimer) — L22.11 fixture sum + cost_note.
9. `tests/integration/phase5-telemetry-test.sh` NEW + `tests/run-all.sh` L22 wiring + static greps.

## Proving tests (L22.1–L22.11)

All deterministic, **no model calls** — static fixture JSON through the helpers.
L22.7 is the key one: it asserts the jq-before-awk + stream-split ship together (a
fixture `.json` through the inline extraction → `STATUS=pass`; the raw awk on the
same `.json` → empty STATUS, demonstrating the broken intermediate state).

## Deferred

`reviewer_models` wiring (Task has no per-call `--model`); `--max-turns` (CLI
doesn't have it); production main-session cap (no prod entrypoint found; evals/run.sh
already caps); scaffold `--resume` cost accounting (per-invocation vs cumulative —
probe before trusting scaffold telemetry).

## Open questions (verify before relying)

1. **`--agent` + `--output-format json` envelope shape** — workers dispatch with
   `--agent claudehut:claudehut-builder` when resolvable; does that path still emit
   a well-formed JSON envelope with `.result`/`.subtype`/`.total_cost_usd`? If
   `--agent` suppresses the envelope, `.result` extraction returns empty → every
   task FAILs. The proving tests use the no-agent path + static fixtures only.
   **Needs a one-off live smoke probe** before production reliance.
2. scaffold `--resume` cost semantics (per-invocation vs cumulative).
3. production main-session cap (no entrypoint outside evals/).
