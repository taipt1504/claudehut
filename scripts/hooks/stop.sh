#!/usr/bin/env bash
# claudehut Stop hook — suggest next phase action based on artifact-derived state
set -euo pipefail

# shellcheck source=lib/state.sh
source "$(dirname "$0")/lib/state.sh"

PROJECT_ROOT="$(claudehut_project_root)"
[[ -d "$PROJECT_ROOT/.claudehut" ]] || exit 0

TASK_ID="$(claudehut_task_id)"
PHASE="$(claudehut_phase "$TASK_ID")"

case "$PHASE" in
  learn)
    jq -n '{
      hookSpecificOutput: {
        hookEventName: "Stop",
        additionalContext: "Verify/Review gates green. Invoke /claudehut:learn to persist learnings."
      }
    }'
    ;;
  done)
    jq -n '{
      hookSpecificOutput: {
        hookEventName: "Stop",
        additionalContext: "Task complete. Run claudehut-finish to archive findings + state. Then merge."
      }
    }'
    ;;
  *)
    exit 0
    ;;
esac
exit 0
