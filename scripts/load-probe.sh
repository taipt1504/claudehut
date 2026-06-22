#!/usr/bin/env bash
# Authoritative plugin LOAD probe (EVAL-REPORT #1 / audit A.2).
#
# `claude plugin validate` only checks marketplace.json — it did NOT catch the P6
# over-declare bug that broke runtime load. The authoritative check is to actually
# load the plugin headlessly and inspect the system/init event:
#   - claudehut present in plugins[]
#   - plugin_errors == []
#
# Needs the `claude` CLI + a working auth session, so it is a release-checklist /
# local step, not a public-CI step. Exit 0 iff the plugin loads cleanly.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

command -v claude >/dev/null 2>&1 || { echo "FAIL - claude CLI not found"; exit 2; }
command -v jq     >/dev/null 2>&1 || { echo "FAIL - jq not found"; exit 2; }

echo "== load-probe: claude -p --plugin-dir $ROOT =="
out="$(claude -p "noop — load probe, do nothing" \
        --plugin-dir "$ROOT" \
        --output-format stream-json 2>/dev/null || true)"

# The system/init event carries the loaded-plugin roster and any load errors.
init="$(printf '%s\n' "$out" | jq -c 'select(.type=="system" and .subtype=="init")' 2>/dev/null | head -1)"
if [ -z "$init" ]; then
  echo "FAIL - no system/init event in stream (probe could not start)"
  exit 1
fi

loaded="$(printf '%s' "$init" | jq -r '[.plugins[]?] | map(select(.name=="claudehut" or (.id // "" | startswith("claudehut")))) | length' 2>/dev/null || echo 0)"
errors="$(printf '%s' "$init"  | jq -c '.plugin_errors // []' 2>/dev/null || echo '[]')"

echo "  claudehut_loaded: $loaded"
echo "  plugin_errors:    $errors"

if [ "$loaded" -ge 1 ] && [ "$errors" = "[]" ]; then
  echo "PASS - plugin loads cleanly"
  exit 0
fi
echo "FAIL - plugin did not load cleanly (loaded=$loaded errors=$errors)"
exit 1
