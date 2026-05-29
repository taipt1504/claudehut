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

# Canonicalize to the physical path. Workers run in git worktrees under temp dirs,
# and on macOS /tmp→/private/tmp and /var→/private/var are symlinks: the tool's
# file_path arrives canonicalized (/private/...) while CLAUDE_PROJECT_DIR may be
# the /tmp/... form. Without this, the relative-path strip below no-ops and every
# in-scope worker write is wrongly denied. (Found by the real Gradle e2e.)
PROJECT_ROOT="$(cd "$PROJECT_ROOT" 2>/dev/null && pwd -P || echo "$PROJECT_ROOT")"

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

# Canonicalize the file path to physical form too (its dir exists even if the
# file is new), so the /tmp↔/private/tmp prefix match below is apples-to-apples.
_fp_dir="$(cd "$(dirname "$file_path")" 2>/dev/null && pwd -P || echo "$(dirname "$file_path")")"
file_path="$_fp_dir/$(basename "$file_path")"

# Always allow writes inside .claudehut/
case "$file_path" in
  "$PROJECT_ROOT/.claudehut/"*) exit 0 ;;
esac

# Stub-scaffold bypass: scaffold-stubs.sh runs a `claude -p` session at phase=build
# to write the WHOLE feature skeleton in one pass — including legitimate files no
# single task owns (shared enums, base types, package-info). Surgical scope +
# reuse-scan freshness are per-task gates that must NOT apply to scaffolding.
[[ -n "${CLAUDEHUT_SCAFFOLD:-}" ]] && exit 0

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

# Build phase: reuse-scan freshness for new Java/Kotlin.
# Skipped for parallel workers (CLAUDEHUT_WORKER): a worker's RED step creates a
# NEW *Test.java (scaffold deliberately writes no tests), which would trip this
# freshness gate — and a headless `-p` worker cannot run /reuse-scan to satisfy it,
# so it would hang to the watchdog. The reuse decision was already made at plan
# time; re-gating it per-write is wrong for a worker. Scope-check below stays live.
if [[ -z "${CLAUDEHUT_WORKER:-}" ]] && [[ "$file_path" =~ \.(java|kt|kts)$ ]] && [[ ! -f "$file_path" ]]; then
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
