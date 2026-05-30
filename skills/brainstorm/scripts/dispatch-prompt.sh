#!/usr/bin/env bash
# scripts/dispatch-prompt.sh — emit the subagent task prompt for THIS phase.
#
# Composition order (each section guarded by file existence):
#   1. User intent (the original prompt)
#   2. Active task id + phase + retry count
#   3. Stack signals (.claudehut/memory/stack-signals.md)
#   4. Conventions (.claudehut/memory/conventions.md)
#   5. Recent learnings (.claudehut/memory/learnings-recent.md)
#   6. Prior-phase artifacts (design.md / contract.md / plan.md / findings.json — whichever apply)
#   7. Current plan task (if phase=build)
#   8. The phase-specific instruction footer (Quick start steps from SKILL.md)
#
# Output is plain markdown — fed verbatim to Task(prompt=...).
set -euo pipefail

USER_PROMPT="${1:-}"
PHASE="brainstorm"

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

cat <<HDR
# ClaudeHut $PHASE — task dispatch

**Task id**: $TASK_ID
**Phase (derived)**: $PHASE_DERIVED
**Loop retries**: $RETRIES/3

## User intent

$USER_PROMPT
HDR

emit_section "Stack signals"      "$PROJECT_ROOT/.claudehut/memory/stack-signals.md"   60
emit_section "Project conventions" "$PROJECT_ROOT/.claudehut/memory/conventions.md"    300
# Phase 4: JIT relevance retrieval of the top-k learnings RELEVANT to this task
# (replaces the head-200 recency dump). The ranker is self-degrading and never
# exits non-zero; the `|| true` is belt-and-suspenders so it can never abort this
# `set -euo pipefail` dispatch or truncate the prompt.
bash "$PLUGIN_ROOT/skills/learn/scripts/retrieve-relevant.sh" "$PROJECT_ROOT" "$USER_PROMPT" "$TASK_ID" || true

# Prior-phase artifacts
emit_section "Design doc"   "$PROJECT_ROOT/.claudehut/specs/${TASK_ID}-design.md"      500
emit_section "Contract"     "$PROJECT_ROOT/.claudehut/specs/${TASK_ID}-contract.md"    500
emit_section "Plan"         "$PROJECT_ROOT/.claudehut/plans/${TASK_ID}-plan.md"        500
emit_section "Findings"     "$PROJECT_ROOT/.claudehut/findings/${TASK_ID}-findings.json" 500

cat <<FTR

## Instructions

Execute this phase per your agent definition (Goals, Gates, Guardrails,
Heuristics in agents/claudehut-brainstormer.md). Write artifacts
under \`.claudehut/\` then return a structured summary to the
orchestrator.
FTR
