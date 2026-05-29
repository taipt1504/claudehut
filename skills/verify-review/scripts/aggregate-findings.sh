#!/usr/bin/env bash
# aggregate-findings.sh <task-id>
#
# Merge per-reviewer shards + the verifier's verify stanza into the canonical
# findings file, compute totals, and decide pass/fail.
#
#   shards    : .claudehut/findings/<task-id>/reviewer-*.json
#               each shard: {"reviewer": "<full-agent-name>", "findings": [ {severity,...} ], "completed_at": "..."}
#   canonical : .claudehut/findings/<task-id>-findings.json   (resolved via state.sh)
#
# Decision rule (fintech): pass  ==  verify gates all pass  AND  critical == 0  AND  high == 0.
# Zero reviewer shards => decision=fail (mandatory review never ran; never a false pass).
#
# Single reader: called from the MAIN thread after all reviewers returned, so the
# shard merge has no concurrent writers (each reviewer wrote its own file).
# Bash 3.2 / POSIX-awk safe; jq required (already a plugin dependency).
set -euo pipefail

TASK_ID="${1:-}"
[[ -n "$TASK_ID" ]] || { echo "usage: aggregate-findings.sh <task-id>" >&2; exit 2; }

_find_plugin_root() {
  if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" ]]; then echo "$CLAUDE_PLUGIN_ROOT"; return; fi
  local d
  d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
  while [[ "$d" != "/" && -n "$d" ]]; do
    [[ -f "$d/.claude-plugin/plugin.json" ]] && { echo "$d"; return; }
    d="$(dirname "$d")"
  done
  echo "error: cannot locate plugin root" >&2; exit 1
}
PLUGIN_ROOT="$(_find_plugin_root)"
# shellcheck source=../../../hooks/lib/state.sh
source "$PLUGIN_ROOT/hooks/lib/state.sh"

FINDINGS_DIR="$(claudehut_claudehut_dir)/findings"
SHARD_DIR="$FINDINGS_DIR/$TASK_ID"
CANONICAL="$FINDINGS_DIR/${TASK_ID}-findings.json"

mkdir -p "$FINDINGS_DIR"
[[ -f "$CANONICAL" ]] || printf '{"reviewers":{}}\n' > "$CANONICAL"

# Verify gates: pass if no verify stanza (not yet evaluated) OR every gate status == pass.
if jq -e '.verify' "$CANONICAL" >/dev/null 2>&1; then
  VERIFY_PASS="$(jq -r '[.verify[]?.status] | all(. == "pass")' "$CANONICAL" 2>/dev/null || echo "false")"
else
  VERIFY_PASS="true"
fi

# Collect reviewer shards (Bash 3.2-safe empty-glob handling).
shopt -s nullglob
SHARDS=("$SHARD_DIR"/reviewer-*.json)
shopt -u nullglob

# Zero-shard guard: mandatory review never ran -> cannot be a pass.
if [[ "${#SHARDS[@]}" -eq 0 ]]; then
  tmp="$(mktemp "${CANONICAL}.XXXXXX")"
  jq '.totals = {critical:0,high:0,medium:0,low:0}
      | .decision = "fail"
      | .aggregate_note = "no reviewer shards found"' \
    "$CANONICAL" > "$tmp" && mv "$tmp" "$CANONICAL"
  jq '{decision: .decision, totals: .totals}' "$CANONICAL"
  exit 0
fi

# Merge each shard's findings into .reviewers[<name>] (deep-merge: preserves any
# completed_at marker written by the SubagentStop hook), then compute totals.
MERGED_REVIEWERS="$(jq -s '
  reduce .[] as $s ({};
    . + { ($s.reviewer // "unknown"): { findings: ($s.findings // []), completed_at: ($s.completed_at // "") } })
' "${SHARDS[@]}")"

TOTALS="$(jq -s '
  [.[].findings[]?]
  | { critical: (map(select(.severity=="critical")) | length),
      high:     (map(select(.severity=="high"))     | length),
      medium:   (map(select(.severity=="medium"))   | length),
      low:      (map(select(.severity=="low"))      | length) }
' "${SHARDS[@]}")"

CRITICAL="$(printf '%s' "$TOTALS" | jq -r '.critical')"
HIGH="$(printf '%s' "$TOTALS" | jq -r '.high')"

if [[ "$VERIFY_PASS" == "true" && "$CRITICAL" -eq 0 && "$HIGH" -eq 0 ]]; then
  DECISION="pass"
else
  DECISION="fail"
fi

tmp="$(mktemp "${CANONICAL}.XXXXXX")"
jq --argjson reviewers "$MERGED_REVIEWERS" \
   --argjson totals "$TOTALS" \
   --arg decision "$DECISION" \
   '.reviewers = ((.reviewers // {}) * $reviewers)
    | .totals = $totals
    | .decision = $decision
    | del(.aggregate_note)' \
   "$CANONICAL" > "$tmp" && mv "$tmp" "$CANONICAL"

jq '{decision: .decision, totals: .totals}' "$CANONICAL"
