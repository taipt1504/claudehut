#!/usr/bin/env bash
# watch-test-fail.sh — verify a test FAILS (RED phase discipline)
# Exits 0 if the test failed (which is what we want).
# Exits 1 if the test passed (RED step incorrect; restart).
# Exits 2 if the test errored on setup (test infrastructure broken).

set -uo pipefail

SPEC="${1:-}"
[[ -z "$SPEC" ]] && { echo "usage: watch-test-fail.sh <test-spec>" >&2; exit 2; }

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
cd "$PROJECT_ROOT"

if [[ -f "gradlew" ]]; then
  CMD="./gradlew test --tests '$SPEC' --quiet"
elif [[ -f "pom.xml" ]]; then
  CMD="mvn test -Dtest='$SPEC' -q"
else
  echo "error: no gradlew or pom.xml found" >&2
  exit 2
fi

# Run and capture
OUTPUT="$(eval "$CMD" 2>&1)" || EXIT=$?
EXIT=${EXIT:-0}

if [[ $EXIT -eq 0 ]]; then
  echo "❌ RED STEP FAILED — test PASSED on first run."
  echo "   You're testing existing behavior. DELETE this test and write one that asserts NEW behavior."
  echo "$OUTPUT" | tail -10
  exit 1
fi

# Check for setup error vs assertion failure
if echo "$OUTPUT" | grep -qE 'Exception in @Before|@BeforeAll|@BeforeEach.*Error'; then
  echo "❌ RED STEP UNCLEAR — error in test setup (@BeforeEach/@BeforeAll)."
  echo "   Fix test infrastructure, not production code."
  echo "$OUTPUT" | tail -10
  exit 2
fi

echo "✓ RED confirmed — test failed as expected."
echo "$OUTPUT" | grep -E 'FAILED|Failures:|Errors:' | head -5
exit 0
