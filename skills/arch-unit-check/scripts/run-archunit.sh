#!/usr/bin/env bash
# run-archunit.sh — execute ArchUnit tests if configured
set -uo pipefail

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
cd "$PROJECT_ROOT"

TASK_ID="${1:-$(cat .claudehut/state/active-task.json 2>/dev/null | jq -r '.task_id // "adhoc"')}"
OUT_DIR=".claudehut/state/tasks/$TASK_ID"
mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/archunit-findings.json"

# Detect ArchUnit on classpath
HAS_ARCHUNIT=0
if [[ -f "build.gradle" ]] && grep -q "archunit" build.gradle 2>/dev/null; then
  HAS_ARCHUNIT=1
elif [[ -f "build.gradle.kts" ]] && grep -q "archunit" build.gradle.kts 2>/dev/null; then
  HAS_ARCHUNIT=1
elif [[ -f "pom.xml" ]] && grep -q "archunit" pom.xml 2>/dev/null; then
  HAS_ARCHUNIT=1
fi

if [[ $HAS_ARCHUNIT -eq 0 ]]; then
  jq -nc '{status: "skipped", reason: "ArchUnit not on classpath", findings: []}' > "$OUT"
  cat "$OUT"
  exit 0
fi

# Run tests matching ArchUnit pattern
if [[ -f "gradlew" ]]; then
  ./gradlew test --tests '*Architecture*' --tests '*ArchTest*' 2>&1 | tee "$OUT_DIR/archunit-output.log"
elif [[ -f "pom.xml" ]]; then
  mvn test -Dtest='*Architecture*,*ArchTest*' 2>&1 | tee "$OUT_DIR/archunit-output.log"
fi

EXIT=$?

# Parse simple pass/fail
if [[ $EXIT -eq 0 ]]; then
  jq -nc '{status: "pass", findings: []}' > "$OUT"
else
  # Extract violation hints from log (heuristic)
  violations=$(grep -E "Architecture Violation|was violated" "$OUT_DIR/archunit-output.log" 2>/dev/null | head -10 | jq -R -s 'split("\n") | map(select(length > 0))')
  jq -nc --argjson v "$violations" '{status: "fail", findings: $v}' > "$OUT"
fi

cat "$OUT" | jq '{status, findings_count: (.findings | length)}'
exit $EXIT
