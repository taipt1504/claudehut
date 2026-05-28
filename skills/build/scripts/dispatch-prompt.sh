#!/usr/bin/env bash
# scripts/dispatch-prompt.sh — emit the subagent task prompt for Phase 4 Build.
#
# Usage: dispatch-prompt.sh "<user-intent>" [<task-number>]
#
# When <task-number> is provided (parallel execution), the prompt includes ONLY
# that task's block and instructs the builder to execute exactly that one task.
# When omitted (legacy single-builder mode), the full plan is included.
#
# Composition order:
#   1. User intent
#   2. Active task id + phase + retry count + assigned task number (if any)
#   3. Stack signals
#   4. Conventions
#   5. Recent learnings
#   6. Prior-phase artifacts (design / contract / plan)
#   7. Single task block (when TASK_NUM set) OR full plan header
#   8. Instruction footer
#
# Output is plain markdown — fed verbatim to Agent(prompt=...).
set -euo pipefail

USER_PROMPT="${1:-}"
TASK_NUM="${2:-}"   # optional: specific task number for parallel dispatch
PHASE="build"

_find_plugin_root() {
  if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" ]]; then echo "$CLAUDE_PLUGIN_ROOT"; return; fi
  local d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
  while [[ "$d" != "/" && -n "$d" ]]; do
    [[ -f "$d/.claude-plugin/plugin.json" ]] && { echo "$d"; return; }
    d="$(dirname "$d")"
  done
  exit 1
}
PLUGIN_ROOT="$(_find_plugin_root)"
source "$PLUGIN_ROOT/hooks/lib/state.sh"

PROJECT_ROOT="$(claudehut_project_root)"
TASK_ID="$(claudehut_task_id)"
PHASE_DERIVED="$(claudehut_phase "$TASK_ID")"
RETRIES="$(claudehut_loop_retries 2>/dev/null || echo 0)"

emit_section() {
  local title="$1" path="$2" max_lines="${3:-200}"
  [[ -f "$path" ]] || return 0
  echo ""
  echo "## $title"
  echo ""
  head -n "$max_lines" "$path"
}

TASK_LABEL=""
[[ -n "$TASK_NUM" ]] && TASK_LABEL=" | assigned task: $TASK_NUM"

cat <<HDR
# ClaudeHut $PHASE — task dispatch

**Task id**: $TASK_ID
**Phase (derived)**: $PHASE_DERIVED
**Loop retries**: $RETRIES/3${TASK_LABEL}

## User intent

$USER_PROMPT
HDR

emit_section "Stack signals"       "$PROJECT_ROOT/.claudehut/memory/stack-signals.md"    60
emit_section "Project conventions" "$PROJECT_ROOT/.claudehut/memory/conventions.md"     300
emit_section "Recent learnings"    "$PROJECT_ROOT/.claudehut/memory/learnings-recent.md" 200

# Prior-phase artifacts
emit_section "Design doc" "$PROJECT_ROOT/.claudehut/specs/${TASK_ID}-design.md"  500
emit_section "Contract"   "$PROJECT_ROOT/.claudehut/specs/${TASK_ID}-contract.md" 500

# Plan: when TASK_NUM provided, emit only the header + that task block.
# Otherwise emit the full plan (legacy single-builder mode).
PLAN_FILE="$PROJECT_ROOT/.claudehut/plans/${TASK_ID}-plan.md"
if [[ -n "$TASK_NUM" && -f "$PLAN_FILE" ]]; then
  echo ""
  echo "## Plan (header + Task $TASK_NUM only)"
  echo ""
  # Emit plan header (lines before first "## Task")
  awk '/^## Task [0-9]/{exit} {print}' "$PLAN_FILE"
  echo ""
  # Emit only the requested task block
  awk "/^## Task ${TASK_NUM}:/{found=1} found{print} found && /^---$/{exit}" "$PLAN_FILE"
else
  emit_section "Plan" "$PLAN_FILE" 500
fi

emit_section "Findings" "$PROJECT_ROOT/.claudehut/findings/${TASK_ID}-findings.json" 500

if [[ -n "$TASK_NUM" ]]; then
  cat <<FTR

## Instructions

Execute **Task ${TASK_NUM} only** per your agent definition (claudehut-builder.md).
Do NOT proceed to other tasks. After RED → GREEN → REFACTOR → commit, emit the
\`claudehut-builder-result\` block and terminate.
FTR
else
  cat <<FTR

## Instructions

Execute this phase per your agent definition (Goals, Gates, Guardrails,
Heuristics in agents/claudehut-builder.md). Write artifacts
under \`.claudehut/\` then return a structured summary to the orchestrator.
FTR
fi
