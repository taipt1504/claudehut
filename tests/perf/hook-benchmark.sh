#!/usr/bin/env bash
# tests/perf/hook-benchmark.sh
#
# Measures p95 latency per hook against design budget (from 70-hooks-specification.md).
# Runs each hook N times in a fixture project, records timing, asserts p95 ≤ budget.

set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
N_RUNS=20
PASS=0; FAIL=0
declare -a FAIL_LIST=()

pass() { printf "  \033[32m✓\033[0m %-30s p95=%4dms (budget %dms)\n" "$1" "$2" "$3"; PASS=$((PASS+1)); }
fail() { printf "  \033[31m✗\033[0m %-30s p95=%4dms (budget %dms) BREACH\n" "$1" "$2" "$3"; FAIL=$((FAIL+1)); FAIL_LIST+=("$1: p95=${2}ms > ${3}ms"); }

p95() {
  local n=$#
  local idx=$(( (n * 95 + 99) / 100 - 1 ))
  [[ $idx -lt 0 ]] && idx=0
  printf '%s\n' "$@" | sort -n | sed -n "$((idx + 1))p"
}

bench_hook() {
  local name="$1"
  local budget_ms="$2"
  local script="$3"
  local stdin_json="$4"
  local hook_args="${5:-}"

  local timings=()
  for ((i=0; i<N_RUNS; i++)); do
    local start_ns end_ns
    start_ns=$(python3 -c 'import time; print(int(time.time()*1e9))')
    if [[ -n "$hook_args" ]]; then
      echo "$stdin_json" | bash "$script" $hook_args >/dev/null 2>&1
    else
      echo "$stdin_json" | bash "$script" >/dev/null 2>&1
    fi
    end_ns=$(python3 -c 'import time; print(int(time.time()*1e9))')
    local elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
    timings+=("$elapsed_ms")
  done

  local p95_val
  p95_val=$(p95 "${timings[@]}")

  if [[ "$p95_val" -le "$budget_ms" ]]; then
    pass "$name" "$p95_val" "$budget_ms"
  else
    fail "$name" "$p95_val" "$budget_ms"
  fi
}

# Setup fixture
TMPDIR=$(mktemp -d)
cd "$TMPDIR"
git init -q
git config user.email test@test
git config user.name Test
git checkout -q -b feature/perf 2>/dev/null
mkdir -p .claudehut/{specs,plans,memory,findings,reuse-scans} src/main/java/com/x
cat > .claudehut/memory/stack-signals.json <<'STACK'
{"web_stack":"webflux","orm":["r2dbc"],"db":["postgresql"],"mapper":"mapstruct","serialization":"jackson","messaging":[],"cache":[]}
STACK

export CLAUDE_PROJECT_DIR="$TMPDIR"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

echo "===== HOOK PERFORMANCE BENCHMARK ====="
echo "Runs per hook: $N_RUNS · Reporting p95 latency"
echo ""

# Budgets from docs/design/70-hooks-specification.md
bench_hook "SessionStart"     2000 "$PLUGIN_ROOT/scripts/hooks/session-start.sh" '{}'
bench_hook "UserPromptSubmit"  200 "$PLUGIN_ROOT/scripts/hooks/prompt-router.sh" '{"prompt":"hello"}'
bench_hook "PreToolUse(bash)"  300 "$PLUGIN_ROOT/scripts/hooks/pre-tool.sh" '{"tool_input":{"command":"./gradlew test"}}' "--tool bash"
bench_hook "PreToolUse(edit)"  300 "$PLUGIN_ROOT/scripts/hooks/pre-tool.sh" "{\"tool_input\":{\"file_path\":\"$TMPDIR/src/main/java/com/x/Foo.java\"}}" "--tool edit"
bench_hook "PostToolUse"       500 "$PLUGIN_ROOT/scripts/hooks/post-tool.sh" "{\"tool_input\":{\"file_path\":\"$TMPDIR/src/main/java/com/x/Foo.java\"}}"
bench_hook "Stop"             1000 "$PLUGIN_ROOT/scripts/hooks/stop.sh" '{}'
bench_hook "PreCompact"        500 "$PLUGIN_ROOT/scripts/hooks/pre-compact.sh" '{}'
bench_hook "FileChanged"       200 "$PLUGIN_ROOT/scripts/hooks/file-changed.sh" '{"file_path":"/tmp/x.md"}'
bench_hook "SubagentStop"      500 "$PLUGIN_ROOT/scripts/hooks/subagent-stop.sh" '{"agent_type":"claudehut-reviewer-security"}'

cd "$PLUGIN_ROOT"
rm -rf "$TMPDIR"

echo ""
echo "===== SUMMARY ====="
printf "Total: %d   \033[32mPass: %d\033[0m   \033[31mFail: %d\033[0m\n" $((PASS+FAIL)) "$PASS" "$FAIL"

if [[ "$FAIL" -gt 0 ]]; then
  echo ""
  echo "BUDGET BREACHES:"
  for f in "${FAIL_LIST[@]}"; do echo "  - $f"; done
  exit 1
fi
exit 0
