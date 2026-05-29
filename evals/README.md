# ClaudeHut Eval Harness

Makes plugin changes **falsifiable**: measures real, representative tasks so the
router (Phase 3), memory/retrieval (Phase 4), and model-tier choices can be
**A/B-proven** instead of asserted. (Per the upgrade plan §9.C.)

## Layout

```
evals/
├── tasks/<name>/
│   ├── task.md        # the user intent prompt fed to the run
│   ├── meta.json      # {class: trivial|small|large, ...}
│   ├── repo/          # starting project — the tree the pipeline works in
│   └── oracle/        # HELD-OUT grading tests — applied AFTER the run, against a
│                      #   copy the pipeline never saw or could edit (so pass@1 is real)
├── score.sh           # deterministic: finished run → one metrics row (no model calls)
├── run.sh             # OPT-IN, real-Claude: runs a task in a mode, scores, appends a row
├── compare.sh         # per-task A/B table from two results files
└── results/<mode>.jsonl
```

## Metrics (per task row)

`terminal_status` + `is_error` (did the run finish, or get killed —
`error_max_budget_usd`/`error_max_turns`), `pass_at_1` (held-out oracle),
`retries` (refactor(loop) commits), `findings` (by severity, from findings.json),
`coverage_line`, `cost_usd`, `wall_ms`.

**Read `pass_at_1` with `terminal_status`.** A killed run scores `pass_at_1=0`
because the oracle grades an *unfinished* tree — that is "never finished", **not**
"finished and got it wrong". The two fields together stop the row from lying by
omission.

**Cost** = main-session `total_cost_usd` (orchestrator + in-process Task
subagents) + Σ `.claudehut/logs/*.cost` (Path-B build workers). Build workers do
not yet emit `.cost` (Phase-5 telemetry), so **claudehut-mode cost is
undercounted by the build-worker spend**; **baseline mode (no workers) is exact**.
`total_cost_usd` is a client-side estimate (Anthropic SDK docs).

## Usage (opt-in — costs API tokens)

```bash
evals/run.sh trivial-sum-bug baseline     # plain Claude Code
evals/run.sh trivial-sum-bug claudehut    # full plugin pipeline (expensive)
evals/compare.sh evals/results/claudehut.jsonl evals/results/baseline.jsonl
```

`CLAUDEHUT_EVAL_BUDGET` (default 2.00 USD) caps each run; `CLAUDEHUT_EVAL_MODEL`
(default sonnet).

## Adding a fixture

Create `tasks/<name>/{task.md, meta.json, repo/, oracle/}`. The oracle test class
name must match `*Oracle*` (run.sh/score.sh run only those). Keep `repo/` minimal
and fast (plain Gradle+JUnit is fine — full Spring Boot is slow to start). Seed
set should span the **router extremes**: a trivial fix (skipping phases saves
most) and a large feature (full pipeline justified).

## Status

Seed fixture: `trivial-sum-bug` (class: trivial). The scorer is CI-tested
(deterministic). Two real rows produced (see results/):

| mode | terminal_status | pass@1 | cost | wall |
|------|-----------------|--------|------|------|
| baseline | success | 1 | $0.14 | 13s |
| claudehut | **error_max_budget_usd** | 0\* | $1.24 | 288s |

\* claudehut was **killed by the $1.00 budget cap mid-pipeline** (after
brainstorm + reuse-scan, before Build) — `pass@1=0` grades an unfinished tree, so
it is *not* a capability verdict. The real, uncontaminated finding: **full
ceremony on a 1-line bug burned ~9× baseline's full-fix cost and never reached the
fix.** That is the empirical case for **adaptive-depth routing (Phase 3)** — a
trivial task should not pay the full 6-phase tax. Whether claudehut *completes and
fixes* at a higher budget is an open, opt-in re-run (~$3–4).

The full Spring suite (Kafka+DLT, Flyway, reactive handler, larger feature) and a
higher-budget claudehut run are the next opt-in additions.
