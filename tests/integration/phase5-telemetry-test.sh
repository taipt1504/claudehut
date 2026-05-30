#!/usr/bin/env bash
# phase5-telemetry-test.sh — Phase 5 proving tests (cost telemetry 5.2, budget
# gate 5.1, model-tier 5.3). DETERMINISTIC, NO model calls — static fixtures only.
# Wired into tests/run-all.sh as section L22.
set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd -P)"
CAP="$PLUGIN_ROOT/skills/build/scripts/capture-telemetry.sh"
RWM="$PLUGIN_ROOT/skills/build/scripts/resolve-worker-model.sh"
GATE="$PLUGIN_ROOT/skills/build/scripts/budget-gate.sh"
PASS=0; FAIL=0; declare -a FL=()
ok() { printf "  \033[32m✓\033[0m %s\n" "$1"; PASS=$((PASS+1)); }
no() { printf "  \033[31m✗\033[0m %s :: %s\n" "$1" "$2"; FAIL=$((FAIL+1)); FL+=("$1: $2"); }

FIX='{"total_cost_usd":0.003421,"usage":{"input_tokens":12000,"output_tokens":800,"cache_read_input_tokens":4500,"cache_creation_input_tokens":0},"num_turns":5,"duration_ms":12400,"subtype":"success","is_error":false,"result":"```claudehut-builder-result\n{\"verify_status\":\"pass\"}\n```"}'

# --- L22.1 capture happy-path: .cost + run-summary row + .result recovery ---
d="$(mktemp -d)"; printf '%s' "$FIX" > "$d/w.json"
bash "$CAP" "$d/w.json" build g1t3 claude-sonnet-4-6 "$d/logs" 777 >/dev/null
cf="$d/logs/build-g1t3-p777.cost"
{ [[ "$(cat "$cf" 2>/dev/null)" == "0.003421" ]] \
  && [[ "$(jq -r '.in_tok' "$d/logs/run-summary.jsonl")" == "12000" ]] \
  && [[ "$(jq -r '.cost' "$d/logs/run-summary.jsonl")" == "0.003421" ]] \
  && [[ "$(jq -r '.terminal_status' "$d/logs/run-summary.jsonl")" == "success" ]] \
  && [[ "$(jq -r '.result // empty' "$d/w.json" | grep -c 'claudehut-builder-result')" == "1" ]]; } \
  && ok "L22.1 capture-telemetry happy-path (.cost + row fields + .result recovers the block)" \
  || no "L22.1" "cost=$(cat "$cf" 2>/dev/null) row=$(cat "$d/logs/run-summary.jsonl" 2>/dev/null)"
rm -rf "$d"

# --- L22.2 killed-worker graceful degradation (missing / empty / invalid JSON) ---
d="$(mktemp -d)"; pass2=1
for case in missing empty invalid; do
  case "$case" in
    missing) jf="$d/none.json" ;;
    empty)   jf="$d/e.json"; : > "$jf" ;;
    invalid) jf="$d/x.json"; printf 'NOT JSON {{{\n' > "$jf" ;;
  esac
  bash "$CAP" "$jf" build "k-$case" sonnet "$d/logs" 1 >/dev/null; rc=$?
  [[ "$rc" -eq 0 && "$(cat "$d/logs/build-k-$case-p1.cost" 2>/dev/null)" == "0.000000" ]] || pass2=0
done
[[ "$pass2" == "1" ]] && ok "L22.2 killed/partial worker → cost 0.000000, exit 0 (no crash)" || no "L22.2" "degradation failed"
rm -rf "$d"

# --- L22.3 nonce uniqueness (no date+%s collision) ---
d="$(mktemp -d)"; printf '%s' "$FIX" > "$d/w.json"
bash "$CAP" "$d/w.json" build g1t3 sonnet "$d/logs" 111 >/dev/null
bash "$CAP" "$d/w.json" build g1t3 sonnet "$d/logs" 222 >/dev/null
nfiles="$(ls "$d/logs"/*.cost 2>/dev/null | wc -l | tr -d ' ')"
sum="$(awk '{s+=$1} END{printf "%.6f", s}' "$d/logs"/*.cost 2>/dev/null)"
{ [[ "$nfiles" == "2" ]] && [[ "$sum" == "0.006842" ]]; } \
  && ok "L22.3 distinct nonce → 2 .cost files, sum = 2× (retry spend not lost)" || no "L22.3" "n=$nfiles sum=$sum"
rm -rf "$d"

# --- L22.4 resolve-worker-model precedence + the agents.* (not phase.*) guard ---
cfg="$(mktemp -d)"; mkdir -p "$cfg/.claudehut"
printf '{"agents":{"builder_model":"claude-opus-4-8"},"phase":{"builder_model":"claude-haiku-4-5"}}\n' > "$cfg/.claudehut/claudehut-config.json"
m_env="$(CLAUDEHUT_WORKER_MODEL=claude-haiku-4-5 bash "$RWM" "$PLUGIN_ROOT" "$cfg")"
m_cfg="$(bash "$RWM" "$PLUGIN_ROOT" "$cfg")"
m_def="$(bash "$RWM" '' '')"
m_bad="$(CLAUDEHUT_WORKER_MODEL=bogus-xyz bash "$RWM" '' '' 2>/dev/null)"
[[ "$m_env" == "claude-haiku-4-5" ]] && ok "L22.4a env override wins" || no "L22.4a" "got $m_env"
[[ "$m_cfg" == "claude-opus-4-8" ]] && ok "L22.4b config agents.builder_model wins (over env unset)" || no "L22.4b" "got $m_cfg"
[[ "$m_def" == "sonnet" ]] && ok "L22.4c default sonnet" || no "L22.4c" "got $m_def"
[[ "$m_bad" == "sonnet" ]] && ok "L22.4d unrecognized id → fallback sonnet + warn" || no "L22.4d" "got $m_bad"
# regression: config with ONLY phase.builder_model (the WRONG key) → must NOT resolve it
cfg2="$(mktemp -d)"; mkdir -p "$cfg2/.claudehut"
printf '{"phase":{"builder_model":"claude-haiku-4-5"}}\n' > "$cfg2/.claudehut/claudehut-config.json"
m_wrongkey="$(bash "$RWM" "$PLUGIN_ROOT" "$cfg2")"
[[ "$m_wrongkey" == "sonnet" ]] && ok "L22.4e phase.builder_model is the WRONG key → ignored (agents.* is correct)" || no "L22.4e" "phase.* wrongly used: $m_wrongkey"
rm -rf "$cfg" "$cfg2"

# --- L22.5 budget-gate launch (worker budget = min(max_worker, remaining/n)) ---
out="$(bash "$GATE" 1.00 4 8.00 4.00 0.50)"
[[ "$out" == "launch 1.75" ]] && ok "L22.5 gate launch: min(4.00,(8-1)/4)=1.75" || no "L22.5" "got '$out'"

# --- L22.6 budget-gate skip + zero-cap unlimited ---
sk="$(bash "$GATE" 7.60 4 8.00 4.00 0.50)"
un="$(bash "$GATE" 0 4 '' 4.00 0.50)"
un0="$(bash "$GATE" 0 4 0 4.00 0.50)"
{ [[ "$sk" == skip* ]] && [[ "$un" == "launch " ]] && [[ "$un0" == "launch " ]]; } \
  && ok "L22.6 gate skip on breach; empty/0 pool → unlimited launch (backward-compat)" || no "L22.6" "skip='$sk' un='$un' un0='$un0'"

# --- L22.8 budget-kill row: subtype/is_error captured, cost still recorded ---
d="$(mktemp -d)"
printf '%s' '{"total_cost_usd":1.23,"subtype":"error_max_budget_usd","is_error":true,"result":""}' > "$d/k.json"
bash "$CAP" "$d/k.json" build g2t1 sonnet "$d/logs" 9 >/dev/null
{ [[ "$(cat "$d/logs/build-g2t1-p9.cost")" == "1.230000" ]] \
  && [[ "$(jq -r '.terminal_status' "$d/logs/run-summary.jsonl")" == "error_max_budget_usd" ]] \
  && [[ "$(jq -r '.is_error' "$d/logs/run-summary.jsonl")" == "true" ]]; } \
  && ok "L22.8 budget-killed worker → row terminal_status=error_max_budget_usd, cost still recorded" || no "L22.8" "$(cat "$d/logs/run-summary.jsonl")"
rm -rf "$d"

# --- L22.9 scaffold path: capture via /dev/stdin, task=scaffold ---
d="$(mktemp -d)"
printf '%s' "$FIX" | bash "$CAP" /dev/stdin build scaffold sonnet "$d/logs" 5 >/dev/null
{ [[ "$(jq -r '.task' "$d/logs/run-summary.jsonl")" == "scaffold" ]] \
  && [[ "$(jq -r '.cost' "$d/logs/run-summary.jsonl")" == "0.003421" ]]; } \
  && ok "L22.9 scaffold telemetry via /dev/stdin (task=scaffold)" || no "L22.9" "$(cat "$d/logs/run-summary.jsonl" 2>/dev/null)"
rm -rf "$d"

echo ""
echo "phase5-telemetry: Pass=$PASS Fail=$FAIL"
[[ "$FAIL" -gt 0 ]] && { printf '  - %s\n' "${FL[@]}"; exit 1; } || exit 0
