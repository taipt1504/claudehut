#!/usr/bin/env bash
# plan-spec-coverage.sh — verify every AC in contract maps to ≥ 1 task in plan
# Compatible with bash 3.2+ (macOS default; no mapfile).
set -euo pipefail

PLAN="${1:-}"
CONTRACT="${2:-}"
[[ -f "$PLAN" ]] || { echo "error: plan not found: $PLAN" >&2; exit 2; }
[[ -f "$CONTRACT" ]] || { echo "error: contract not found: $CONTRACT" >&2; exit 2; }

# Extract AC ids from contract (lines like "### AC-1:" or "AC-1 ...")
ACS="$(grep -oE '\bAC-[0-9]+\b' "$CONTRACT" | sort -u)"

if [[ -z "$ACS" ]]; then
  echo "warning: no AC- identifiers in contract" >&2
  exit 0
fi

n_total=0
n_missing=0
missing=""
for ac in $ACS; do
  n_total=$((n_total+1))
  if ! grep -qE "\b$ac\b" "$PLAN"; then
    missing="$missing $ac"
    n_missing=$((n_missing+1))
  fi
done

if [[ $n_missing -gt 0 ]]; then
  echo "❌ Plan misses these acceptance criteria:$missing" >&2
  exit 1
fi
echo "Plan spec coverage: $n_total/$n_total ✓"
exit 0
