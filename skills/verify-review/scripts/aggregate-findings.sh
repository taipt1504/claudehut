#!/usr/bin/env bash
# aggregate-findings.sh — merge per-reviewer findings into totals and decision
set -euo pipefail

FINDINGS="${1:-}"
[[ -f "$FINDINGS" ]] || { echo "error: findings file not found: $FINDINGS" >&2; exit 2; }

# Compute totals across reviewers
jq '
  .totals = (
    [.reviewers[] | .findings[]?]
    | group_by(.severity)
    | map({key: .[0].severity, value: length})
    | from_entries
    | { critical: (.critical // 0), high: (.high // 0), medium: (.medium // 0), low: (.low // 0) }
  )
  | .decision = (if (.totals.critical == 0 and .totals.high < 3) then "pass" else "fail" end)
' "$FINDINGS" > "${FINDINGS}.tmp"

mv "${FINDINGS}.tmp" "$FINDINGS"
jq '{decision: .decision, totals: .totals}' "$FINDINGS"
