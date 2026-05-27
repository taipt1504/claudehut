#!/usr/bin/env bash
# tests/e2e/run-real-claude.sh
#
# Real Claude Code E2E test runner — spawns `claude --plugin-dir` with prompt
# fixtures and asserts expected skills/agents activated. Opt-in test (not in CI
# default) because requires Claude installed + costs API tokens.
#
# Pattern adopted from obra/superpowers tests/skill-triggering/.
#
# Usage:
#   tests/e2e/run-real-claude.sh                # run all prompts
#   tests/e2e/run-real-claude.sh 01             # run specific prompt by prefix
#
# Requires:
#   - `claude` CLI in PATH
#   - `jq` for stream-json parsing
#   - Claude API access (subscription or Anthropic Console)

set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PROMPTS_DIR="$PLUGIN_ROOT/tests/e2e/prompts"
OUT_DIR="$PLUGIN_ROOT/tests/e2e/.runs/$(date +%Y%m%d-%H%M%S)"
FILTER="${1:-}"

mkdir -p "$OUT_DIR"

# Pre-flight
command -v claude >/dev/null || { echo "error: claude CLI not in PATH"; exit 2; }
command -v jq >/dev/null || { echo "error: jq not in PATH"; exit 2; }

PASS=0; FAIL=0
declare -a FAIL_LIST=()

pass() { printf "  \033[32m✓\033[0m %s\n" "$1"; PASS=$((PASS+1)); }
fail() { printf "  \033[31m✗\033[0m %s :: %s\n" "$1" "$2"; FAIL=$((FAIL+1)); FAIL_LIST+=("$1: $2"); }

run_prompt() {
  local prompt_file="$1"
  local name="$(basename "$prompt_file" .txt)"
  [[ -n "$FILTER" && "$name" != "$FILTER"* ]] && return 0

  echo ""
  echo "===== Prompt: $name ====="
  local prompt
  prompt="$(cat "$prompt_file")"
  echo "Input: $prompt"

  local log="$OUT_DIR/${name}.log"
  local json="$OUT_DIR/${name}.stream.json"

  # Spawn in a fixture Java project so workflow has something to operate on
  local fixture
  fixture="$OUT_DIR/${name}-fixture"
  mkdir -p "$fixture"
  cd "$fixture"
  git init -q
  git config user.email test@test
  git config user.name Test

  # Mock Java project structure
  mkdir -p src/main/java/com/x/user src/test/java/com/x/user
  cat > pom.xml <<'POM'
<?xml version="1.0"?>
<project>
  <groupId>com.x</groupId>
  <artifactId>fixture</artifactId>
  <version>1.0.0</version>
  <dependencies>
    <dependency><groupId>org.springframework.boot</groupId><artifactId>spring-boot-starter-webflux</artifactId></dependency>
    <dependency><groupId>org.springframework.boot</groupId><artifactId>spring-boot-starter-data-r2dbc</artifactId></dependency>
  </dependencies>
</project>
POM
  cat > src/main/java/com/x/user/User.java <<'JAVA'
package com.x.user;
public record User(String id, String email, String name) {}
JAVA

  # Pre-initialize ClaudeHut so workflow engages (skip init prompt)
  mkdir -p .claudehut/{specs,plans,memory,findings,reuse-scans}
  cat > .claudehut/memory/stack-signals.json <<'STACK'
{"web_stack":"webflux","orm":["r2dbc"],"db":["postgresql"],"messaging":[],"cache":[],"mapper":"manual","serialization":"jackson","build_tool":"maven","java_version":"21","spring_boot":"3.3.4","test":{"junit":"5.10","testcontainers":false,"wiremock":false},"detected_at":"2025-05-27T00:00:00Z"}
STACK
  cat > .claudehut/claudehut-config.json <<'CFG'
{"version":"0.1.0","phase":{"loop_max_retries":3}}
CFG

  echo "# fixture" > README.md
  git add . >/dev/null 2>&1
  git commit -m init >/dev/null 2>&1

  # Run claude with portable timeout (macOS has no `timeout`)
  TIMEOUT_BIN=$(command -v timeout || command -v gtimeout || echo "")
  if [[ -n "$TIMEOUT_BIN" ]]; then
    "$TIMEOUT_BIN" 180 claude \
      --plugin-dir "$PLUGIN_ROOT" \
      --dangerously-skip-permissions \
      --output-format stream-json \
      --verbose \
      -p "$prompt" \
      > "$json" 2>"$log" || true
  else
    # Manual timeout via background + sleep + kill
    claude \
      --plugin-dir "$PLUGIN_ROOT" \
      --dangerously-skip-permissions \
      --output-format stream-json \
      --verbose \
      -p "$prompt" \
      > "$json" 2>"$log" &
    cpid=$!
    ( sleep 180 && kill -TERM "$cpid" 2>/dev/null ) &
    tpid=$!
    wait "$cpid" 2>/dev/null || true
    kill -TERM "$tpid" 2>/dev/null || true
    wait 2>/dev/null || true
  fi

  cd "$PLUGIN_ROOT"

  # Extract assistant text for semantic matching (uses jq parse)
  local assistant_text
  assistant_text=$(jq -r 'select(.type == "assistant") | .message.content[]? | select(.type=="text") | .text' "$json" 2>/dev/null | tr '\n' ' ')

  # Extract hooks fired
  local hooks_fired
  hooks_fired=$(jq -r 'select(.type == "system" and .subtype == "hook_started") | .hook_event' "$json" 2>/dev/null | sort -u | tr '\n' ',')

  # Assertions per prompt
  case "$name" in
    01-feature-intent-on-main)
      # Universal: ClaudeHut SessionStart hook fired
      if echo "$hooks_fired" | grep -q SessionStart; then
        pass "$name: SessionStart hook fired"
      else
        fail "$name" "SessionStart hook not fired"
      fi
      # Universal: prompt-router suggested branch creation (uninitialized OR main)
      if echo "$assistant_text" | grep -qiE 'branch|claudehut:init|claudehut.6.phase|workflow'; then
        pass "$name: workflow engagement (branch/init/6-phase mentioned)"
      else
        fail "$name" "no workflow engagement: ${assistant_text:0:200}"
      fi
      ;;
    02-brainstorm-skill-triggered)
      # ClaudeHut should be active + brainstorm guidance
      if echo "$assistant_text" | grep -qiE 'brainstorm|design|clarify|claudehut'; then
        pass "$name: brainstorm intent recognized"
      else
        fail "$name" "no brainstorm recognition"
      fi
      # SessionStart hook fired (UserPromptSubmit may not fire in -p mode)
      if echo "$hooks_fired" | grep -q SessionStart; then
        pass "$name: SessionStart hook fired"
      else
        fail "$name" "SessionStart hook not fired"
      fi
      ;;
    03-skip-attempt-blocked)
      # Skip-attempt should either be hard-blocked (0 turns, 0 cost) OR
      # Claude explained enforcement instead of writing code
      local num_turns
      num_turns=$(jq -r 'select(.type == "result") | .num_turns // 999' "$json" 2>/dev/null | head -1)
      local input_tokens
      input_tokens=$(jq -r 'select(.type == "result") | .usage.input_tokens // 999' "$json" 2>/dev/null | head -1)

      if [[ "$num_turns" == "0" ]] && [[ "$input_tokens" == "0" ]]; then
        pass "$name: HARD BLOCKED (0 turns, 0 tokens, 0 cost — workflow enforced)"
      elif echo "$assistant_text" | grep -qiE 'cannot.*skip|enforces.*pipeline|6.phase|brainstorm|spec.*first|workflow'; then
        pass "$name: skip handled via assistant response (num_turns=$num_turns)"
      else
        fail "$name" "skip not enforced: num_turns=$num_turns text=${assistant_text:0:200}"
      fi
      ;;
    *)
      pass "$name: ran without crash (no specific assertion)"
      ;;
  esac

  # Always-on: count hook events fired
  local n_hooks
  n_hooks=$(jq -s 'map(select(.type == "system" and .subtype == "hook_started")) | length' "$json" 2>/dev/null || echo 0)
  echo "  Hooks fired: $n_hooks ($hooks_fired)"
}

echo "ClaudeHut E2E (real Claude) — output in $OUT_DIR"

for f in "$PROMPTS_DIR"/*.txt; do
  [[ -f "$f" ]] && run_prompt "$f"
done

echo ""
echo "===== SUMMARY ====="
printf "Total: %d   \033[32mPass: %d\033[0m   \033[31mFail: %d\033[0m\n" \
  $((PASS+FAIL)) "$PASS" "$FAIL"

if [[ "$FAIL" -gt 0 ]]; then
  echo ""
  echo "FAILURES:"
  for f in "${FAIL_LIST[@]}"; do echo "  - $f"; done
  exit 1
fi
exit 0
