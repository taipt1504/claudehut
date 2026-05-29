#!/usr/bin/env bash
# score.sh <task-name> <run-dir> [--claude-json FILE] [--wall-ms N] [--mode M]
#
# Deterministic scorer: given a FINISHED run (the post-pipeline working copy in
# <run-dir>, plus the captured `claude --output-format json` result and timing),
# compute one metrics row. No model calls here — pure extraction, so this is
# CI-testable against a synthetic finished-run fixture.
#
# pass@1 is graded with the HELD-OUT oracle (evals/tasks/<task>/oracle/) — those
# tests are copied into a throwaway COPY of <run-dir> and run there, so the
# pipeline never saw or could edit them. Requires `gradle`; if absent, pass@1 is
# null (extraction metrics still computed).
#
# Cost = main-session total_cost_usd (covers the orchestrator + in-process Task
# subagents) + Σ(.claudehut/logs/*.cost) for Path-B build workers. NOTE: build
# workers do not yet emit .cost (Phase 5 telemetry), so claudehut-mode cost is
# UNDERCOUNTED by the build-worker spend; baseline mode (no workers) is exact.
# `total_cost_usd` is a client-side estimate (per Anthropic SDK docs).
set -euo pipefail

TASK="${1:?usage: score.sh <task> <run-dir> [opts]}"
RUN_DIR="${2:?usage: score.sh <task> <run-dir> [opts]}"
shift 2 || true

CLAUDE_JSON=""; WALL_MS="null"; MODE="unknown"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --claude-json) CLAUDE_JSON="${2:-}"; shift 2 ;;
    --wall-ms)     WALL_MS="${2:-null}"; shift 2 ;;
    --mode)        MODE="${2:-unknown}"; shift 2 ;;
    *) echo "score.sh: unknown opt $1" >&2; exit 2 ;;
  esac
done

EVALS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
ORACLE_DIR="$EVALS_DIR/tasks/$TASK/oracle"

# ---- pass@1 via held-out oracle (graded on a throwaway copy) ----
PASS1="null"
if [[ -d "$ORACLE_DIR" ]] && command -v gradle >/dev/null 2>&1 && [[ -f "$RUN_DIR/build.gradle" ]]; then
  GRADE_DIR="$(mktemp -d)"
  cp -R "$RUN_DIR/." "$GRADE_DIR/" 2>/dev/null || true
  rm -rf "$GRADE_DIR/.git" "$GRADE_DIR/build" "$GRADE_DIR/.gradle"
  # Drop the held-out oracle tests into the test source tree (they were never
  # visible to the pipeline) and run ONLY them, so pass@1 is the oracle's verdict
  # — not the agent's own self-authored tests.
  mkdir -p "$GRADE_DIR/src/test/java/com/example"
  cp "$ORACLE_DIR"/*.java "$GRADE_DIR/src/test/java/com/example/" 2>/dev/null || true
  if ( cd "$GRADE_DIR" && gradle test --tests '*Oracle*' -q >/dev/null 2>&1 ); then
    PASS1=1
  else
    PASS1=0
  fi
  rm -rf "$GRADE_DIR"
fi

# ---- retries: count refactor(loop) commits on the run branch ----
RETRIES=0
if git -C "$RUN_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  RETRIES="$(git -C "$RUN_DIR" log --format='%s' 2>/dev/null | grep -c '^refactor(loop)' || true)"
  RETRIES="${RETRIES:-0}"
fi

# ---- reviewer findings: from the canonical findings.json (if the pipeline ran) ----
FINDINGS='{"critical":0,"high":0,"medium":0,"low":0}'
_fjson="$(ls "$RUN_DIR"/.claudehut/findings/*-findings.json 2>/dev/null | head -1 || true)"
if [[ -n "$_fjson" && -f "$_fjson" ]]; then
  FINDINGS="$(jq -c '.totals // {critical:0,high:0,medium:0,low:0}' "$_fjson" 2>/dev/null || echo "$FINDINGS")"
fi

# ---- coverage (JaCoCo) — null in the MVP fixtures (not configured) ----
COVERAGE_LINE="null"

# ---- cost: main session + Σ worker .cost files ----
MAIN_COST=0
[[ -n "$CLAUDE_JSON" && -f "$CLAUDE_JSON" ]] && \
  MAIN_COST="$(jq -r '.total_cost_usd // 0' "$CLAUDE_JSON" 2>/dev/null || echo 0)"
WORKER_COST=0; WORKER_N=0
for c in "$RUN_DIR"/.claudehut/logs/*.cost; do
  [[ -f "$c" ]] || continue
  WORKER_N=$((WORKER_N + 1))
  WORKER_COST="$(awk -v a="$WORKER_COST" -v b="$(cat "$c" 2>/dev/null || echo 0)" 'BEGIN{printf "%.6f", a+b}')"
done
COST="$(awk -v a="$MAIN_COST" -v b="$WORKER_COST" 'BEGIN{printf "%.6f", a+b}')"
COST_NOTE="main-session + ${WORKER_N} worker cost-file(s); client-side estimate; Path-B workers undercounted until Phase-5 telemetry"

jq -n \
  --arg task "$TASK" --arg mode "$MODE" \
  --argjson pass1 "$PASS1" --argjson retries "$RETRIES" \
  --argjson findings "$FINDINGS" --argjson covline "$COVERAGE_LINE" \
  --argjson cost "$COST" --argjson wall "$WALL_MS" \
  --arg note "$COST_NOTE" \
  '{task:$task, mode:$mode, pass_at_1:$pass1, retries:$retries,
    findings:$findings, coverage_line:$covline,
    cost_usd:$cost, wall_ms:$wall, cost_note:$note}'
