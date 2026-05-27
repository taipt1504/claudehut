#!/usr/bin/env bash
# plan-placeholder-scan.sh — reject plans with placeholders or vague language
set -euo pipefail

PLAN="${1:-}"
[[ -f "$PLAN" ]] || { echo "error: file not found: $PLAN" >&2; exit 2; }

issues=0
patterns=(
  '\b(TBD|TODO|FIXME|XXX)\b'
  'similar to task'
  'add validation'
  '\betc\b'
  'and so on'
  '<.*placeholder.*>'
  '\b(handle|manage|process)\b\s+\w+\s*$'
)
for p in "${patterns[@]}"; do
  if grep -nE "$p" "$PLAN" >/dev/null 2>&1; then
    echo "❌ Found pattern: $p" >&2
    grep -nE "$p" "$PLAN" | head -3 >&2
    issues=$((issues + 1))
  fi
done

# Every task needs explicit RED + verify commands
task_count="$(grep -cE '^## Task' "$PLAN" || echo 0)"
red_count="$(grep -cE '^\*\*RED:\*\*' "$PLAN" || echo 0)"
verify_count="$(grep -cE '^\*\*Verify:\*\*' "$PLAN" || echo 0)"

if [[ "$task_count" -gt 0 ]]; then
  if [[ "$red_count" -ne "$task_count" ]]; then
    echo "❌ Tasks=$task_count but RED sections=$red_count" >&2
    issues=$((issues + 1))
  fi
  if [[ "$verify_count" -ne "$task_count" ]]; then
    echo "❌ Tasks=$task_count but Verify sections=$verify_count" >&2
    issues=$((issues + 1))
  fi
fi

if [[ $issues -gt 0 ]]; then
  echo "Plan placeholder scan: $issues issue(s)" >&2
  exit 1
fi
echo "Plan placeholder scan: clean."
exit 0
