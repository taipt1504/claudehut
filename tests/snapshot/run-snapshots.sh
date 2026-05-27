#!/usr/bin/env bash
# tests/snapshot/run-snapshots.sh
#
# Snapshot tests for hook JSON output. Compares hook stdout against golden
# files under tests/snapshot/golden/. Update goldens with --update.

set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GOLDEN_DIR="$PLUGIN_ROOT/tests/snapshot/golden"
UPDATE="${1:-}"

mkdir -p "$GOLDEN_DIR"

PASS=0; FAIL=0
declare -a FAIL_LIST=()

pass() { printf "  \033[32m✓\033[0m %s\n" "$1"; PASS=$((PASS+1)); }
fail() { printf "  \033[31m✗\033[0m %s :: %s\n" "$1" "$2"; FAIL=$((FAIL+1)); FAIL_LIST+=("$1: $2"); }

# Normalize: strip timestamps + paths + session_ids before comparison
normalize() {
  sed -E '
    s|"timestamp":"[^"]*"|"timestamp":"<TS>"|g;
    s|"detected_at":"[^"]*"|"detected_at":"<TS>"|g;
    s|"ts":"[^"]*"|"ts":"<TS>"|g;
    s|/var/folders/[^"]+|<TMPDIR>|g;
    s|/tmp/tmp\.[^"]+|<TMPDIR>|g;
    s|"session_id":"[^"]*"|"session_id":"<SID>"|g;
  '
}

snapshot() {
  local name="$1"
  local script="$2"
  local stdin_json="$3"
  local hook_args="${4:-}"

  local actual_raw
  if [[ -n "$hook_args" ]]; then
    actual_raw=$(echo "$stdin_json" | bash "$script" $hook_args 2>/dev/null)
  else
    actual_raw=$(echo "$stdin_json" | bash "$script" 2>/dev/null)
  fi

  local actual
  actual=$(echo "$actual_raw" | normalize)

  local golden_file="$GOLDEN_DIR/$name.json"

  if [[ "$UPDATE" == "--update" ]]; then
    echo "$actual" > "$golden_file"
    pass "$name (golden updated)"
    return
  fi

  if [[ ! -f "$golden_file" ]]; then
    echo "$actual" > "$golden_file"
    pass "$name (golden created)"
    return
  fi

  local expected
  expected=$(cat "$golden_file")
  if [[ "$actual" == "$expected" ]]; then
    pass "$name"
  else
    fail "$name" "snapshot mismatch — run with --update to regenerate"
    if [[ "${VERBOSE:-0}" == "1" ]]; then
      diff <(echo "$expected") <(echo "$actual") | head -20
    fi
  fi
}

# Setup fixture
TMPDIR=$(mktemp -d)
cd "$TMPDIR"
git init -q
git config user.email test@test
git config user.name Test
git checkout -q -b feature/snapshot 2>/dev/null
mkdir -p .claudehut/{specs,plans,memory,findings,reuse-scans} src/main/java/com/x
cat > .claudehut/memory/stack-signals.json <<'STACK'
{"web_stack":"webflux","orm":["r2dbc"],"db":["postgresql"],"messaging":[],"cache":[],"mapper":"mapstruct","serialization":"jackson"}
STACK

export CLAUDE_PROJECT_DIR="$TMPDIR"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

echo "===== HOOK OUTPUT SNAPSHOTS ====="
echo ""

snapshot "session-start-initialized" "$PLUGIN_ROOT/scripts/hooks/session-start.sh" '{}'
snapshot "session-start-uninitialized" "$PLUGIN_ROOT/scripts/hooks/session-start.sh" '{}' ""
# Reset for next group
rm -rf .claudehut

snapshot "session-start-no-claudehut-dir" "$PLUGIN_ROOT/scripts/hooks/session-start.sh" '{}'

# Re-init for remaining
mkdir -p .claudehut/{specs,plans,memory,findings,reuse-scans}
cat > .claudehut/memory/stack-signals.json <<'STACK'
{"web_stack":"webflux","orm":["r2dbc"],"db":["postgresql"],"messaging":[],"cache":[],"mapper":"mapstruct","serialization":"jackson"}
STACK

snapshot "prompt-router-feature-intent-on-main" "$PLUGIN_ROOT/scripts/hooks/prompt-router.sh" '{"prompt":"add endpoint to fetch user data"}'

snapshot "pre-tool-deny-rm-rf" "$PLUGIN_ROOT/scripts/hooks/pre-tool.sh" '{"tool_input":{"command":"rm -rf /"}}' "--tool bash"
snapshot "pre-tool-allow-safe" "$PLUGIN_ROOT/scripts/hooks/pre-tool.sh" '{"tool_input":{"command":"./gradlew test"}}' "--tool bash"
snapshot "pre-tool-deny-src-wrong-phase" "$PLUGIN_ROOT/scripts/hooks/pre-tool.sh" "{\"tool_input\":{\"file_path\":\"$TMPDIR/src/main/java/com/x/Foo.java\"}}" "--tool edit"
snapshot "pre-tool-allow-claudehut" "$PLUGIN_ROOT/scripts/hooks/pre-tool.sh" "{\"tool_input\":{\"file_path\":\"$TMPDIR/.claudehut/specs/x-design.md\"}}" "--tool edit"

snapshot "stop-no-action-needed" "$PLUGIN_ROOT/scripts/hooks/stop.sh" '{}'
snapshot "pre-compact-snapshot" "$PLUGIN_ROOT/scripts/hooks/pre-compact.sh" '{}'
snapshot "file-changed-claude-md" "$PLUGIN_ROOT/scripts/hooks/file-changed.sh" '{"file_path":"/tmp/CLAUDE.md"}'

cd "$PLUGIN_ROOT"
rm -rf "$TMPDIR"

echo ""
echo "===== SUMMARY ====="
printf "Total: %d   \033[32mPass: %d\033[0m   \033[31mFail: %d\033[0m\n" $((PASS+FAIL)) "$PASS" "$FAIL"

if [[ "$FAIL" -gt 0 ]]; then
  echo ""
  echo "FAILURES:"
  for f in "${FAIL_LIST[@]}"; do echo "  - $f"; done
  echo ""
  echo "Update goldens: bash tests/snapshot/run-snapshots.sh --update"
  exit 1
fi
exit 0
