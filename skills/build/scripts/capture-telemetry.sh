#!/usr/bin/env bash
# capture-telemetry.sh <json-file> <phase> <task> <model> <log-dir> [nonce]
#
# Phase 5.2 — per-worker cost/token telemetry. Reads a headless worker's
# `claude --output-format json` envelope and writes:
#   (a) a BARE float `<phase>-<task>-p<nonce>.cost` (the exact format evals/score.sh
#       sums via `cat` → awk), and
#   (b) one JSONL row to run-summary.jsonl: {phase,task,model,in_tok,out_tok,
#       cache_read_tok,cache_write_tok,cost,num_turns,ms,terminal_status,is_error}.
#
# SELF-DEGRADING: a SIGTERM/budget-killed worker emits no or partial JSON; every
# jq extraction is `// 0`-guarded so that yields zeros and exit 0 — telemetry is 0,
# never a crash of the orchestrator. NO model calls (CI-testable on a static
# fixture). Called ONLY from the single-threaded post-wait collection loop (no
# flock — unavailable on macOS bash 3.2).
#
# Nonce: callers pass their own PID ($$). run-parallel-group.sh is re-invoked as a
# NEW process per group and per loop-retry, so (task, $$) is unique across the run
# — no date+%s second-collision, no undefined $RETRIES.
set -uo pipefail

JSON="${1:?usage: capture-telemetry.sh <json-file> <phase> <task> <model> <log-dir> [nonce]}"
PHASE="${2:-build}"
TASK="${3:-unknown}"
MODEL="${4:-unknown}"
LOG_DIR="${5:?log-dir required}"
NONCE="${6:-$$}"

command -v jq >/dev/null 2>&1 || exit 0
mkdir -p "$LOG_DIR" 2>/dev/null || exit 0

# Numeric field with a hard 0 fallback (missing file / partial JSON / non-number).
_num() {
  local v
  v="$(jq -r "$1 // 0" "$JSON" 2>/dev/null || echo 0)"
  case "$v" in ''|*[!0-9.]*) echo 0 ;; *) echo "$v" ;; esac
}
COST="$(_num '.total_cost_usd')"
IN="$(_num '.usage.input_tokens')"
OUT="$(_num '.usage.output_tokens')"
CR="$(_num '.usage.cache_read_input_tokens')"
CW="$(_num '.usage.cache_creation_input_tokens')"
TURNS="$(_num '.num_turns')"
MS="$(_num '.duration_ms')"
SUB="$(jq -r '.subtype // "unknown"' "$JSON" 2>/dev/null || echo unknown)"
[[ -n "$SUB" ]] || SUB="unknown"
ERR="$(jq -r 'if .is_error==true then "true" else "false" end' "$JSON" 2>/dev/null || echo false)"
[[ "$ERR" == "true" || "$ERR" == "false" ]] || ERR="false"

# (a) bare-float .cost
COST_FILE="$LOG_DIR/${PHASE}-${TASK}-p${NONCE}.cost"
awk -v c="$COST" 'BEGIN{printf "%.6f\n", c+0}' > "$COST_FILE" 2>/dev/null || printf '0.000000\n' > "$COST_FILE"

# (b) run-summary.jsonl row (append; single-threaded caller → race-free)
jq -cn \
  --arg ph "$PHASE" --arg t "$TASK" --arg m "$MODEL" \
  --argjson it "$IN" --argjson ot "$OUT" --argjson cr "$CR" --argjson cw "$CW" \
  --argjson cost "$COST" --argjson nt "$TURNS" --argjson ms "$MS" \
  --arg sub "$SUB" --argjson err "$ERR" \
  '{phase:$ph,task:$t,model:$m,in_tok:$it,out_tok:$ot,cache_read_tok:$cr,cache_write_tok:$cw,cost:$cost,num_turns:$nt,ms:$ms,terminal_status:$sub,is_error:$err}' \
  >> "$LOG_DIR/run-summary.jsonl" 2>/dev/null || true

exit 0
