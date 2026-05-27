#!/usr/bin/env bash
# secret-scan.sh — scan text or file for secret patterns
# Usage: secret-scan.sh <file>   OR   echo "text" | secret-scan.sh -
# Exit 0 if clean, 1 if any pattern matched
set -euo pipefail

INPUT="${1:-}"
if [[ "$INPUT" == "-" || -z "$INPUT" ]]; then
  CONTENT="$(cat)"
else
  [[ -f "$INPUT" ]] || { echo "error: file not found: $INPUT" >&2; exit 2; }
  CONTENT="$(cat "$INPUT")"
fi

PATTERNS=(
  'sk-[a-zA-Z0-9_-]{20,}'
  'AKIA[0-9A-Z]{16}'
  '-----BEGIN ((RSA|EC|DSA|OPENSSH) )?PRIVATE KEY-----'
  'ghp_[a-zA-Z0-9]{36}'
  'github_pat_[a-zA-Z0-9_]{82}'
  'gho_[a-zA-Z0-9]{36}'
  'xox[baprs]-[0-9a-zA-Z-]{10,}'
  'glpat-[0-9a-zA-Z_-]{20}'
  'eyJ[a-zA-Z0-9_-]{20,}\.eyJ[a-zA-Z0-9_-]{20,}\.[a-zA-Z0-9_-]{20,}'
  'postgres(ql)?://[^:]+:[^@]+@'
  'mongodb(\+srv)?://[^:]+:[^@]+@'
  'redis://[^:]+:[^@]+@'
)

issues=0
for p in "${PATTERNS[@]}"; do
  if echo "$CONTENT" | grep -qE -- "$p"; then
    # Don't print the matched text — privacy
    echo "❌ Pattern matched: $p" >&2
    issues=$((issues + 1))
  fi
done

if [[ $issues -gt 0 ]]; then
  echo "secret-scan: $issues secret pattern(s) detected" >&2
  exit 1
fi
exit 0
