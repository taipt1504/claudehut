#!/usr/bin/env bash
# claudehut PreToolUse hook — destructive-cmd block, phase gate (src/ in build),
# reuse-scan freshness, surgical-scope enforce. Rule injection now lives in
# Claude Code's native `.claude/rules/` loader (see hooks/pre-tool.sh tail).
set -euo pipefail

# shellcheck source=lib/state.sh
source "$(dirname "$0")/lib/state.sh"

input="$(cat)"

PROJECT_ROOT="$(claudehut_project_root)"
[[ -d "$PROJECT_ROOT/.claudehut" ]] || exit 0

tool_mode="edit"
for arg in "$@"; do
  case "$arg" in
    --tool) shift; tool_mode="${1:-edit}" ;;
  esac
done

# Bash mode: destructive command check
if [[ "$tool_mode" == "bash" ]]; then
  cmd="$(echo "$input" | jq -r '.tool_input.command // ""')"
  if echo "$cmd" | grep -qE '\brm -rf /|\bgit push.* --force\b|DROP DATABASE|\bkubectl delete\b|--no-verify\b'; then
    jq -n --arg c "$cmd" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: "ClaudeHut: destructive command blocked: \($c). Add allowlist entry in claudehut-config.json#phase.destructive_command_allowlist if intentional."
      }
    }'
    exit 0
  fi
  exit 0
fi

# Edit/Write mode
file_path="$(echo "$input" | jq -r '.tool_input.file_path // ""')"
[[ -n "$file_path" ]] || exit 0

# Always allow writes inside .claudehut/
case "$file_path" in
  "$PROJECT_ROOT/.claudehut/"*) exit 0 ;;
esac

TASK_ID="$(claudehut_task_id)"
PHASE="$(claudehut_phase "$TASK_ID")"

# Source-code edits blocked outside build phase
if [[ "$PHASE" != "build" ]]; then
  case "$file_path" in
    *.java|*.kt|*.kts|*.sql|src/*)
      jq -n --arg p "$PHASE" --arg f "$file_path" '{
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
          permissionDecision: "deny",
          permissionDecisionReason: "ClaudeHut: source-code edits not allowed in phase=\($p). File: \($f). Create the required .claudehut/ artifact for current phase first."
        }
      }'
      exit 0
      ;;
  esac
  exit 0
fi

# Build phase: reuse-scan freshness for new Java/Kotlin
if [[ "$file_path" =~ \.(java|kt|kts)$ ]] && [[ ! -f "$file_path" ]]; then
  if ! claudehut_reuse_scan_fresh "$TASK_ID"; then
    jq -n --arg f "$file_path" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: "ClaudeHut: creating new file \($f) requires fresh reuse-scan (< 10 min). Run /claudehut:reuse-scan <topic> first."
      }
    }'
    exit 0
  fi
fi

# Surgical scope: file must appear in current plan
PLAN="$(claudehut_plan_doc "$TASK_ID")"
if [[ -n "$PLAN" ]]; then
  rel="${file_path#$PROJECT_ROOT/}"
  if ! grep -qE "(create|modify|test):.*\b${rel//./\\.}\b" "$PLAN"; then
    jq -n --arg f "$rel" --arg p "$PLAN" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: "ClaudeHut: file \($f) not in current plan (\($p)). Edit plan to add file under correct task (or split into new task), commit plan edit, then retry. Don'\''t silently expand scope."
      }
    }'
    exit 0
  fi
fi

# Rule auto-load is handled natively: <project>/.claude/rules/*.md files
# (copied from the plugin by /claudehut:init) carry `paths:` frontmatter and
# are loaded by Claude Code's built-in loader when matching files are read.
exit 0
