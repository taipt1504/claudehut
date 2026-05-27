#!/usr/bin/env bash
# pre-write-scope-check.sh — verify the target file is in the current task's scope
# Usage: pre-write-scope-check.sh <file>
# Exit 0 if in scope, 1 if not.
set -euo pipefail

_find_plugin_root() {
  if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" ]]; then echo "$CLAUDE_PLUGIN_ROOT"; return; fi
  local d
  d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
  while [[ "$d" != "/" && -n "$d" ]]; do
    [[ -f "$d/.claude-plugin/plugin.json" ]] && { echo "$d"; return; }
    d="$(dirname "$d")"
  done
  echo "error: cannot locate ClaudeHut plugin root" >&2; exit 1
}
# shellcheck source=../../../hooks/lib/state.sh
source "$(_find_plugin_root)/hooks/lib/state.sh"

FILE="${1:-}"
[[ -n "$FILE" ]] || { echo "error: no file argument" >&2; exit 2; }

PROJECT_ROOT="$(claudehut_project_root)"
task_id="$(claudehut_active_task)"
[[ "$task_id" == "none" ]] && exit 0

plan="$PROJECT_ROOT/.claudehut/plans/$task_id-plan.md"
[[ -f "$plan" ]] || exit 0  # no plan = no scope check

# Auto-allow paths
case "$FILE" in
  "$PROJECT_ROOT/.claudehut/"*) exit 0 ;;
  "$PROJECT_ROOT/$plan") exit 0 ;;
esac

# Extract all paths from plan task blocks
rel_file="${FILE#$PROJECT_ROOT/}"
if grep -qE "(create|modify|test): .${rel_file}\`?" "$plan"; then
  exit 0
fi
# Loose match without leading dot
if grep -qE "(create|modify|test): \`?${rel_file}\`?" "$plan"; then
  exit 0
fi

echo "scope: $rel_file not in plan" >&2
exit 1
