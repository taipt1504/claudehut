#!/usr/bin/env bash
# claudehut Stop hook — suggest next phase action based on artifact-derived state.
#
# Schema note: the Stop event does NOT accept `hookSpecificOutput`. Only top-level
# fields are valid (decision/reason/systemMessage/stopReason/continue/suppressOutput).
# We use:
#   - decision="block" + reason  → force Claude to continue with the next phase task
#   - systemMessage              → informational, non-blocking
set -euo pipefail

# shellcheck source=lib/state.sh
source "$(dirname "$0")/lib/state.sh"

PROJECT_ROOT="$(claudehut_project_root)"
[[ -d "$PROJECT_ROOT/.claudehut" ]] || exit 0

TASK_ID="$(claudehut_task_id)"
PHASE="$(claudehut_phase "$TASK_ID")"

case "$PHASE" in
  learn)
    # Learn phase still pending → block stop, force Claude to dispatch the learner.
    jq -n '{
      decision: "block",
      reason: "Verify/Review gates are green but the Learn phase has not run. Invoke /claudehut:learn (dispatches claudehut-learner) before stopping so patterns are persisted to .claudehut/memory/learnings.jsonl."
    }'
    ;;
  done)
    # Task complete → non-blocking suggestion.
    jq -n '{
      systemMessage: "ClaudeHut: task complete. Run claudehut-finish to archive findings + state, then merge."
    }'
    ;;
  *)
    exit 0
    ;;
esac
exit 0
