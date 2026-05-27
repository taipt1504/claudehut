#!/usr/bin/env bash
# claudehut PreCompact hook — surface phase + task before context compaction
set -euo pipefail

# shellcheck source=lib/state.sh
source "$(dirname "$0")/lib/state.sh"

PROJECT_ROOT="$(claudehut_project_root)"
[[ -d "$PROJECT_ROOT/.claudehut" ]] || exit 0

TASK_ID="$(claudehut_task_id)"
PHASE="$(claudehut_phase "$TASK_ID")"
DESIGN="$(claudehut_design_doc "$TASK_ID")"
CONTRACT="$(claudehut_contract_doc "$TASK_ID")"
PLAN="$(claudehut_plan_doc "$TASK_ID")"

ctx="ClaudeHut state pre-compact:
Task=$TASK_ID, Phase=$PHASE
Artifacts:
  design:   ${DESIGN:-none}
  contract: ${CONTRACT:-none}
  plan:     ${PLAN:-none}

After compact: re-read these artifacts + run claudehut-state phase to resume."

jq -n --arg c "$ctx" '{
  hookSpecificOutput: {
    hookEventName: "PreCompact",
    additionalContext: $c
  }
}'
exit 0
