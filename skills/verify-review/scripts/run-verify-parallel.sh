#!/usr/bin/env bash
# run-verify-parallel.sh — execute verify gates in parallel where possible
# Usage: run-verify-parallel.sh <project-root>
# Writes results to <project-root>/.claudehut/state/tasks/<task-id>/findings.json (verify section)
set -euo pipefail

PROJECT_ROOT="${1:-${CLAUDE_PROJECT_DIR:-$(pwd)}}"
cd "$PROJECT_ROOT"

# Detect build tool
if [[ -f "gradlew" ]]; then
  BUILD="gradlew"
elif [[ -f "pom.xml" ]]; then
  BUILD="maven"
else
  echo "error: no build file (gradlew or pom.xml) found" >&2
  exit 2
fi

LOG_DIR="$(mktemp -d)"
BUILD_PID=""

run_gate() {
  local name="$1" cmd="$2"
  ( eval "$cmd" >"$LOG_DIR/$name.out" 2>"$LOG_DIR/$name.err" && echo PASS > "$LOG_DIR/$name.status" || echo FAIL > "$LOG_DIR/$name.status" ) &
  echo $! > "$LOG_DIR/$name.pid"
}

if [[ "$BUILD" == "gradlew" ]]; then
  run_gate "build"  "./gradlew compileJava compileTestJava"
  wait "$(cat "$LOG_DIR/build.pid")"
  [[ "$(cat "$LOG_DIR/build.status")" == "PASS" ]] || { echo "build failed; see $LOG_DIR/build.err"; exit 1; }

  run_gate "test"     "./gradlew test"
  run_gate "lint"     "./gradlew spotlessCheck"
  run_gate "static"   "./gradlew spotbugsMain"
  wait
  run_gate "integration" "./gradlew integrationTest"
  run_gate "coverage"    "./gradlew jacocoTestReport jacocoTestCoverageVerification"
  wait
fi

# Emit summary
echo "{"
sep=""
for f in "$LOG_DIR"/*.status; do
  name="$(basename "$f" .status)"
  status="$(cat "$f")"
  echo "$sep  \"$name\": \"$status\""
  sep=","
done
echo "}"
