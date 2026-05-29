#!/usr/bin/env bash
# claudehut UserPromptSubmit hook — phase gate enforcement via artifact-derived state
set -euo pipefail

# shellcheck source=lib/state.sh
source "$(dirname "$0")/lib/state.sh"

input="$(cat)"
prompt="$(echo "$input" | jq -r '.prompt // ""')"

# Worker/scaffold sessions are headless `claude -p` sub-processes spawned by the
# Build phase. They must NOT be phase-routed or skip-phrase-blocked: a block on a
# non-interactive session can never be satisfied → the worker hangs until its
# watchdog kills it. PreToolUse scope-check stays active (different hook).
[[ -n "${CLAUDEHUT_WORKER:-}" ]] && exit 0

PROJECT_ROOT="$(claudehut_project_root)"
[[ -d "$PROJECT_ROOT/.claudehut" ]] || exit 0

TASK_ID="$(claudehut_task_id)"
PHASE="$(claudehut_phase "$TASK_ID")"

# Block skip-attempt language
if echo "$prompt" | grep -qiE '\b(just write the code|skip (the )?(spec|plan|brainstorm|review)|no need for (spec|plan|test|review)|ignore phases?)\b'; then
  jq -n --arg p "$PHASE" '{
    decision: "block",
    reason: "ClaudeHut enforces 6-phase pipeline. Current phase=\($p). Phases cannot be skipped. Create the required artifact (design → contract → plan) to advance."
  }'
  exit 0
fi

# Intent detection — feature work on default branch
INTENT_REGEX='\b(add|implement|build|design|refactor|fix bug|create) (feature|endpoint|service|class|module|api|handler|controller|listener|consumer|migration)\b'
if [[ "$PHASE" == "none" ]] && echo "$prompt" | grep -qiE "$INTENT_REGEX"; then
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "UserPromptSubmit",
      additionalContext: "ClaudeHut: feature intent detected on default branch. Create a feature branch first:\n  git checkout -b feature/<slug>\nOR claudehut-worktree-create feature/<slug> for isolated workspace.\nBranch name becomes task_id; phase derived from artifacts."
    }
  }'
  exit 0
fi

case "$PHASE" in
  brainstorm) HINT="Phase=brainstorm. Use /claudehut:brainstorm. Output: .claudehut/specs/${TASK_ID}-design.md → phase advances automatically." ;;
  spec)       HINT="Phase=spec. Use /claudehut:spec. Output: .claudehut/specs/${TASK_ID}-contract.md → phase advances automatically." ;;
  plan)       HINT="Phase=plan. Use /claudehut:plan. Output: .claudehut/plans/${TASK_ID}-plan.md with all tasks unchecked → phase advances." ;;
  build)      HINT="Phase=build. Per plan task: RED → GREEN → REFACTOR. Tick checkbox in plan when done. Surgical scope enforced." ;;
  loop)       HINT="Phase=loop. Invoke /claudehut:verify-review. Writes .claudehut/findings/${TASK_ID}-findings.json (decision: pass|fail)." ;;
  learn)      HINT="Phase=learn. Invoke /claudehut:learn. Appends to .claudehut/memory/learnings.jsonl." ;;
  done)       HINT="Phase=done. Run claudehut-finish. Then merge branch." ;;
  *)          exit 0 ;;
esac

jq -n --arg c "$HINT" '{
  hookSpecificOutput: {
    hookEventName: "UserPromptSubmit",
    additionalContext: $c
  }
}'
exit 0
