#!/usr/bin/env bash
# run-verify-parallel.sh — execute verify gates in parallel where possible
# Usage: run-verify-parallel.sh <project-root>
# Emits verify-gate results as JSON to stdout. The verifier writes them as the
# `verify` stanza of the canonical .claudehut/findings/<task-id>-findings.json.
set -euo pipefail

PROJECT_ROOT="${1:-${CLAUDE_PROJECT_DIR:-$(pwd)}}"
cd "$PROJECT_ROOT"

# Reset the reviewer shard dir at the START of every verify iteration. The Loop
# is iterative (verify → fail → refactor → re-verify); without this, a reviewer
# that is not re-dispatched (or errors) in a later iteration would leave its
# stale shard on disk for aggregate-findings.sh to count → false fail. This is
# the first script the verifier runs each iteration, so the reset is deterministic
# and happens before any reviewer writes a fresh shard.
_rvp_root() {
  if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" ]]; then echo "$CLAUDE_PLUGIN_ROOT"; return; fi
  local d; d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
  while [[ "$d" != "/" && -n "$d" ]]; do
    [[ -f "$d/.claude-plugin/plugin.json" ]] && { echo "$d"; return; }
    d="$(dirname "$d")"
  done
}
_rvp_plugin="$(_rvp_root || true)"
if [[ -n "$_rvp_plugin" && -f "$_rvp_plugin/hooks/lib/state.sh" ]]; then
  # shellcheck source=../../../hooks/lib/state.sh
  source "$_rvp_plugin/hooks/lib/state.sh"
  _rvp_tid="$(claudehut_task_id)"
  if [[ "$_rvp_tid" != "none" ]]; then
    _rvp_shards="$(claudehut_claudehut_dir)/findings/$_rvp_tid"
    rm -rf "$_rvp_shards"; mkdir -p "$_rvp_shards"
  fi
fi

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
