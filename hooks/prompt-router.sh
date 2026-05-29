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
PROFILE="$(claudehut_route_profile "$TASK_ID")"

# Block skip-attempt language. Depth is reduced by RECORDING a route (quick), not
# by ad-hoc prompt requests — so an unrecorded "skip the spec" is still blocked,
# but the corrective action is to route, not to bypass.
if echo "$prompt" | grep -qiE '\b(just write the code|skip (the )?(spec|plan|brainstorm|review)|no need for (spec|plan|test|review)|ignore phases?)\b'; then
  jq -n --arg p "$PHASE" '{
    decision: "block",
    reason: "ClaudeHut sets pipeline depth via routing (/claudehut:route → quick|full), not ad-hoc skips. Current phase=\($p). For a trivial fix, record a quick route (build+verify only); within the chosen profile, phases are not skippable. Verify always runs."
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
  route)      HINT="Phase=route. Use /claudehut:route to triage depth (quick vs full). Output: .claudehut/state/route-${TASK_ID}.json → phase advances automatically. Cheap inline classify, not a subagent." ;;
  brainstorm) HINT="Phase=brainstorm. Use /claudehut:brainstorm. Output: .claudehut/specs/${TASK_ID}-design.md → phase advances automatically." ;;
  spec)       HINT="Phase=spec. Use /claudehut:spec. Output: .claudehut/specs/${TASK_ID}-contract.md → phase advances automatically." ;;
  plan)       HINT="Phase=plan. Use /claudehut:plan. Output: .claudehut/plans/${TASK_ID}-plan.md with all tasks unchecked → phase advances." ;;
  build)
    if [[ "$PROFILE" == "quick" ]]; then
      HINT="Phase=build (QUICK route — no plan). Make the fix INLINE with TDD discipline (/claudehut:tdd-cycle: failing test first → minimal fix → commit). The builder subagent doesn't apply (no plan/Task N/stub-worktree). Then invoke /claudehut:verify-review — the gate still runs. No plan/checkbox; surgical-scope + reuse-scan self-disable."
    else
      HINT="Phase=build. Per plan task: RED → GREEN → REFACTOR. Tick checkbox in plan when done. Surgical scope enforced."
    fi
    ;;
  loop)
    # Deterministically surface the configurable retry cap so the loop can't run
    # forever: read loop_max_retries from config (default 3) and the git-derived
    # retry count. At/over the cap, instruct escalation instead of another refactor.
    _max="$(jq -r '.phase.loop_max_retries // empty' "$PROJECT_ROOT/.claudehut/claudehut-config.json" 2>/dev/null)"
    [[ "$_max" =~ ^[0-9]+$ ]] || _max=3
    _retries="$(claudehut_loop_retries 2>/dev/null || echo 0)"
    if [[ "$_retries" -ge "$_max" ]]; then
      HINT="Phase=loop — RETRY CAP REACHED ($_retries/$_max). Do NOT inject another refactor task. ESCALATE to the user with the full findings and let them decide (accept findings, change scope, or abandon). The retry cap (phase.loop_max_retries) is a hard stop."
    else
      HINT="Phase=loop (retry $_retries/$_max). Invoke /claudehut:verify-review. Writes .claudehut/findings/${TASK_ID}-findings.json (decision: pass|fail)."
    fi
    ;;
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
