#!/usr/bin/env bash
# validate-contract.sh — validate a contract doc for completeness + binary criteria
set -euo pipefail

DOC="${1:-}"
[[ -f "$DOC" ]] || { echo "error: file not found: $DOC" >&2; exit 2; }

issues=0
REQUIRED_SECTIONS=("Acceptance" "API" "Edge cases" "Error" "NFR" "Data contract" "Test surface")

for sec in "${REQUIRED_SECTIONS[@]}"; do
  if ! grep -qE "^#+ .*$sec" "$DOC"; then
    echo "❌ Missing section: $sec" >&2
    issues=$((issues + 1))
  fi
done

# Acceptance criteria must contain GIVEN/WHEN/THEN
if ! grep -qE '\bGIVEN\b.*\bWHEN\b.*\bTHEN\b' "$DOC" && ! awk '/GIVEN/{g=1} /WHEN/{w=1} /THEN/{t=1} END{exit !(g&&w&&t)}' "$DOC"; then
  echo "❌ Acceptance criteria missing Given/When/Then structure" >&2
  issues=$((issues + 1))
fi

# Placeholder scan
if grep -nE '\b(TBD|TODO|FIXME|XXX)\b' "$DOC" >/dev/null 2>&1; then
  echo "❌ Placeholders found:" >&2
  grep -nE '\b(TBD|TODO|FIXME|XXX)\b' "$DOC" | head -5 >&2
  issues=$((issues + 1))
fi

# NFR section should contain a number
if awk '/^#+ .*NFR/,/^#+ [^N]/' "$DOC" | grep -qE '[0-9]+\s*(ms|s|req/s|MB|GB|%)'; then
  :
else
  echo "❌ NFR section lacks numeric thresholds" >&2
  issues=$((issues + 1))
fi

if [[ $issues -gt 0 ]]; then
  echo "Contract validation: $issues issue(s)" >&2
  exit 1
fi
echo "Contract validation: clean."
exit 0
