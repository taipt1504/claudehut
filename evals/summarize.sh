#!/usr/bin/env bash
# summarize.sh — pass rate per task × arm × auth mode from evals/results/{claudehut,baseline}.jsonl, and Δ.
# Aborted runs (budget/turn kills) and rows before 0.12.7 (no auth_mode) are excluded: they say nothing about
# the plugin. Usage: evals/summarize.sh [--since ISO8601] [--json]
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"; R="${CLAUDEHUT_EVAL_RESULTS:-$ROOT/evals/results}"
SINCE=""; JSON=false
while [ $# -gt 0 ]; do case "$1" in --since) SINCE="${2:-}"; shift 2 ;; --json) JSON=true; shift ;; *) shift ;; esac; done
cat "$R/claudehut.jsonl" "$R/baseline.jsonl" 2>/dev/null | jq -sc --arg since "$SINCE" '
  map(select(type=="object" and has("auth_mode") and (.aborted|not) and (.pass_at_1 != null)
             and ($since == "" or (.ts >= $since))))
  | group_by([.task, .auth_mode])
  | map({task: .[0].task, auth: .[0].auth_mode,
         with: ([.[] | select(.mode=="claudehut") | .pass_at_1]), without: ([.[] | select(.mode=="baseline") | .pass_at_1])}
        | .with_rate = (if (.with|length) > 0 then ((.with|add) / (.with|length)) else null end)
        | .without_rate = (if (.without|length) > 0 then ((.without|add) / (.without|length)) else null end)
        | .delta = (if .with_rate != null and .without_rate != null then (.with_rate - .without_rate) else null end)
        | {task, auth, runs_with: (.with|length), runs_without: (.without|length), with_rate, without_rate, delta})' \
| if $JSON; then cat; else jq -r '(["TASK","AUTH","WITH","W/OUT","Δ","RUNS"] | @tsv),
     (.[] | [.task, .auth, (.with_rate // "-" | tostring), (.without_rate // "-" | tostring), (.delta // "-" | tostring),
             "\(.runs_with)/\(.runs_without)"] | @tsv)' | column -t -s $'\t'; fi
exit 0
