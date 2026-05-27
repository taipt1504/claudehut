#!/usr/bin/env bash
# reproduce-helpers.sh — quick reproduction fixtures
# Usage: reproduce-helpers.sh <command>
#   db-snapshot <table>          — dump a table to a fixture file
#   loop-test <gradle-test-spec> — run a test N times to check flakiness
#   freeze-time                  — print a JVM arg to fix time

set -euo pipefail

CMD="${1:-help}"
shift || true

case "$CMD" in
  db-snapshot)
    table="${1:?table required}"
    out="${2:-/tmp/$table-snapshot.sql}"
    pg_dump --data-only --table="$table" >"$out"
    echo "Snapshot: $out"
    ;;
  loop-test)
    spec="${1:?test spec required}"
    runs="${2:-50}"
    fail=0
    for ((i=1; i<=runs; i++)); do
      if ./gradlew test --tests "$spec" -q >/dev/null 2>&1; then
        echo -n "."
      else
        echo -n "F"
        fail=$((fail+1))
      fi
    done
    echo
    echo "Failed: $fail/$runs"
    ;;
  freeze-time)
    iso="${1:-2025-01-01T00:00:00Z}"
    echo "-Dfaketime.iso=$iso  # for libfaketime / jvm test arg"
    echo "Or in test: Clock.fixed(Instant.parse(\"$iso\"), ZoneOffset.UTC)"
    ;;
  *)
    cat <<EOF
reproduce-helpers.sh — debug fixtures

USAGE:
  reproduce-helpers.sh db-snapshot <table> [output.sql]
  reproduce-helpers.sh loop-test <test-spec> [runs]
  reproduce-helpers.sh freeze-time [iso]
EOF
    ;;
esac
