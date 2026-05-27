#!/usr/bin/env bash
# validate-migration.sh — check a migration SQL file for naming + online-safety issues
set -euo pipefail

FILE="${1:-}"
[[ -f "$FILE" ]] || { echo "error: file not found: $FILE" >&2; exit 2; }

issues=0
basename="$(basename "$FILE")"

# Naming
if ! [[ "$basename" =~ ^(V[0-9]+|R)__[a-z][a-z0-9_]*\.sql$ ]]; then
  echo "❌ Naming: must be V<num>__<snake_case>.sql or R__<snake_case>.sql (got: $basename)" >&2
  issues=$((issues + 1))
fi

content="$(cat "$FILE")"

# Online safety — Postgres
if echo "$content" | grep -qiE 'CREATE INDEX[^C]' && ! echo "$content" | grep -qiE 'CREATE INDEX[[:space:]]+CONCURRENTLY'; then
  echo "⚠️  CREATE INDEX without CONCURRENTLY — acquires lock on large tables" >&2
fi

if echo "$content" | grep -qiE 'ALTER TABLE.*ADD COLUMN.*NOT NULL' && ! echo "$content" | grep -qiE 'NOT NULL[[:space:]]*DEFAULT'; then
  echo "❌ ADD COLUMN NOT NULL without DEFAULT — fails on rolling deploy with existing rows" >&2
  issues=$((issues + 1))
fi

if echo "$content" | grep -qiE 'DROP COLUMN'; then
  echo "⚠️  DROP COLUMN — ensure app no longer references this column in active deploy" >&2
fi

if echo "$content" | grep -qiE 'RENAME COLUMN'; then
  echo "⚠️  RENAME COLUMN — use expand-contract pattern instead for rolling deploys" >&2
fi

if echo "$content" | grep -qiE 'LOCK TABLE'; then
  echo "⚠️  Explicit LOCK TABLE — rarely needed; consider alternative" >&2
fi

# Repeatable prefix for DDL
if [[ "$basename" =~ ^R__ ]] && echo "$content" | grep -qiE 'CREATE TABLE|DROP TABLE|ALTER TABLE'; then
  echo "❌ R__ (repeatable) migration contains DDL on tables — use V__ instead" >&2
  issues=$((issues + 1))
fi

if [[ $issues -gt 0 ]]; then
  echo "Migration validation: $issues critical issue(s)" >&2
  exit 1
fi
echo "Migration validation: clean ($basename)"
exit 0
