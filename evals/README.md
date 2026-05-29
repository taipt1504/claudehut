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

`pass_at_1` (held-out oracle), `retries` (refactor(loop) commits), `findings`
(by severity, from findings.json), `coverage_line`, `cost_usd`, `wall_ms`.

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
(deterministic). A real baseline row has been produced (see results/). The full
Spring suite (Kafka+DLT, Flyway, reactive handler, larger feature) and real
claudehut-mode rows are the next opt-in additions.
