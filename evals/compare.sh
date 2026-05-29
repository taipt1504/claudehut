#!/usr/bin/env bash
# compare.sh <results-A.jsonl> <results-B.jsonl>
# Print a per-task A/B table (latest row per task in each file). Falsifies
# "the apparatus helps": compare claudehut vs baseline on pass@1, retries, cost, wall.
set -euo pipefail
A="${1:?usage: compare.sh <A.jsonl> <B.jsonl>}"; B="${2:?usage: compare.sh <A.jsonl> <B.jsonl>}"
[[ -f "$A" && -f "$B" ]] || { echo "both result files must exist" >&2; exit 2; }
_latest() { jq -s --arg t "$1" 'map(select(.task==$t)) | last // {}' "$2"; }
printf '%-22s | %-26s | %-26s\n' "task / metric" "$(basename "$A" .jsonl)" "$(basename "$B" .jsonl)"
printf -- '-%.0s' {1..80}; echo
tasks="$(cat "$A" "$B" | jq -r '.task' | sort -u)"
for t in $tasks; do
  ra="$(_latest "$t" "$A")"; rb="$(_latest "$t" "$B")"
  for m in terminal_status pass_at_1 retries cost_usd wall_ms; do
    va="$(printf '%s' "$ra" | jq -r ".$m // \"-\"")"
    vb="$(printf '%s' "$rb" | jq -r ".$m // \"-\"")"
    printf '%-22s | %-26s | %-26s\n' "$t.$m" "$va" "$vb"
  done
  printf -- '-%.0s' {1..80}; echo
done
