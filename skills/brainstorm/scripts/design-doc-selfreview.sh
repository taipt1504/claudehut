#!/usr/bin/env bash
# design-doc-selfreview.sh — Scan a design doc for placeholders/ambiguity
# Exit 0 if clean, exit 1 if issues found (with stderr listing them)
set -euo pipefail

DOC="${1:-}"
[[ -f "$DOC" ]] || { echo "error: file not found: $DOC" >&2; exit 2; }

issues=0

scan() {
  local pattern="$1" label="$2"
  if grep -nE "$pattern" "$DOC" >/dev/null 2>&1; then
    echo "❌ $label" >&2
    grep -nE "$pattern" "$DOC" | head -5 >&2
    issues=$((issues + 1))
  fi
}

# Placeholders
scan '\b(TBD|TODO|FIXME|XXX)\b' "Placeholder markers (TBD/TODO/FIXME/XXX)"
scan '\b(etc|and so on|similar to)\b' "Vague terminators (etc/and so on/similar to)"

# Section presence
for sec in "Overview" "Components" "Error" "Testing" "NFR"; do
  if ! grep -qE "^#+ .*$sec" "$DOC"; then
    echo "❌ Missing section: $sec" >&2
    issues=$((issues + 1))
  fi
done

# Adjectives instead of numbers in NFR
if awk '/^#+ .*NFR/,/^#+ [^N]/' "$DOC" | grep -qE '\b(fast|slow|good|bad|high|low|some|many|few)\b'; then
  echo "⚠️  NFR section contains adjectives; prefer numeric thresholds" >&2
fi

if [[ $issues -gt 0 ]]; then
  echo "Self-review: $issues issue(s) found." >&2
  exit 1
fi

echo "Self-review: clean."
exit 0
