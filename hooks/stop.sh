#!/usr/bin/env bash
# claudehut Stop hook — surface pending phase actions before the session ends.
#
# Schema note: the Stop event does NOT accept `hookSpecificOutput`. Only top-level
# fields are valid (decision/reason/systemMessage/stopReason/continue/suppressOutput).
#
# Behavior policy (intentional, after real-user feedback):
#   - Default mode: emit `systemMessage` (informational, non-blocking) — Claude
#     is allowed to stop; the user sees a reminder, not a wall.
#   - Hard-enforcement mode (opt-in via .claudehut/claudehut-config.json#
#     phase.stop_enforcement_enabled = true): emit `decision="block"` to force
#     Claude to dispatch the missing phase before stopping. Use sparingly —
#     blocking the Stop event makes Claude continue past the user's stop intent.
set -euo pipefail

# shellcheck source=lib/state.sh
source "$(dirname "$0")/lib/state.sh"

input="$(cat 2>/dev/null || true)"

PROJECT_ROOT="$(claudehut_project_root)"
[[ -d "$PROJECT_ROOT/.claudehut" ]] || exit 0

# Bounded escape: if we have already blocked at least once this stop cycle
# (the platform sets stop_hook_active=true), do NOT block again. An unsatisfiable
# gate (learner crash, billing-tier mismatch, malformed learnings.jsonl) would
# otherwise drive the platform's 3/8-block stop-loop. Downgrade to a non-blocking
# message with a manual escape hatch instead.
STOP_ACTIVE="$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null || echo false)"

# Worker/scaffold sessions (headless `claude -p` from the Build phase) must never
# be Stop-blocked — a non-interactive session cannot dispatch a missing phase and
# would hang until its watchdog kills it. (Currently Stop blocks only at
# phase=learn, which workers never reach; this is defensive against future rules.)
[[ -n "${CLAUDEHUT_WORKER:-}" ]] && exit 0

TASK_ID="$(claudehut_task_id)"
PHASE="$(claudehut_phase "$TASK_ID")"

config="$PROJECT_ROOT/.claudehut/claudehut-config.json"
ENFORCE=false
if [[ -f "$config" ]]; then
  ENFORCE="$(jq -r '.phase.stop_enforcement_enabled // false' "$config" 2>/dev/null)"
fi

case "$PHASE" in
  learn)
    msg="ClaudeHut: Verify/Review gates are green but the Learn phase has not run. Invoke /claudehut:learn (dispatches claudehut-learner) to persist patterns to .claudehut/memory/learnings.jsonl."
    if [[ "$ENFORCE" == "true" && "$STOP_ACTIVE" != "true" ]]; then
      jq -n --arg r "$msg" '{ decision: "block", reason: $r }'
    else
      # Either enforcement is off, or we already blocked once (stop_hook_active) —
      # do not hard-block again; surface a manual escape so the user can exit.
      esc="$msg Could not complete automatically? Run /claudehut:learn manually, or claudehut-finish --skip-learn to exit."
      [[ "$STOP_ACTIVE" == "true" ]] && jq -n --arg m "$esc" '{ systemMessage: $m }' || jq -n --arg m "$msg" '{ systemMessage: $m }'
    fi
    ;;
  done)
    # Task complete → always non-blocking suggestion.
    jq -n '{
      systemMessage: "ClaudeHut: task complete. Run claudehut-finish to archive findings + state, then merge."
    }'
    ;;
  *)
    exit 0
    ;;
esac
exit 0
