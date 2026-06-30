#!/usr/bin/env bash
# SubagentStop hook. Blocks if a file-producing phase subagent returned without its required
# artifact. Default contract (accepted default C3): only agents whose contract is a FILE are
# checked — claudehut-reuse-scanner (tasks/*/reuse-scan.md) and claudehut-planner (tasks/*/plan.md).
# The Review auditors return findings as text (no file) and are not file-checked here.
# Verb name ("verify") — not the retired Verify phase. See 06 §3.
set -euo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
in="$(cat || true)"
command -v jq >/dev/null 2>&1 || exit 0   # degrade: fail open

block() { jq -n --arg r "$1" '{decision:"block",reason:$r}'; exit 0; }

# HANG FIX: a blocking SubagentStop holds the subagent open ("continue working"); without this cap a
# missing/mispathed artifact loops the block forever — an infinite hold that presents as a hang.
# Same native cap gate-done.sh uses: when stop_hook_active is true, stop blocking and fail open.
[ "$(jq -r '.stop_hook_active // false' <<<"$in" 2>/dev/null || echo false)" = "true" ] && exit 0

agent="$(jq -r '.agent_type // empty' <<<"$in" 2>/dev/null || true)"
DIR="$PROJECT_DIR/.claude/claudehut"

case "$agent" in
  claudehut-reuse-scanner)
    # canonical: tasks/<id>/reuse-scan.md ; legacy flat reuse-scan-*.md still accepted
    { ls "$DIR"/tasks/*/reuse-scan.md >/dev/null 2>&1 || ls "$DIR"/reuse-scan-*.md >/dev/null 2>&1; } \
      || block "claudehut-reuse-scanner returned without a reuse-scan artifact (.claude/claudehut/tasks/<NNNN-slug>/reuse-scan.md). Produce it before proceeding."
    ;;
  claudehut-planner)
    # canonical: tasks/<id>/plan.md ; legacy plans/*.md still accepted
    { ls "$DIR"/tasks/*/plan.md >/dev/null 2>&1 || ls "$DIR"/plans/*.md >/dev/null 2>&1; } \
      || block "claudehut-planner returned without a plan file (.claude/claudehut/tasks/<NNNN-slug>/plan.md). Produce it before proceeding."
    ;;
  claudehut-plan-reviewer)
    # WS-2 (issue 2): a DISPATCHED plan-reviewer must return a verdict artifact (tasks/<id>/plan-review.md),
    # so a spawned-but-empty review is blocked. Proxy for "this session": newer than the state file (which
    # bootstrap.sh wrote at SessionStart, before any subagent). Fails open when state/session is absent or no
    # plan-review.md exists at all (never wedge — 06 §5). NB: this proves the agent PRODUCED a verdict when it
    # ran; the set-plan APPROVE gate is what makes the verdict mandatory before the write gate opens.
    sid_pr="$(jq -r '.session_id // empty' <<<"$in" 2>/dev/null || true)"
    STATE_FILE="$DIR/state/$sid_pr.json"
    if [ -n "$sid_pr" ] && [ -f "$STATE_FILE" ] && ls "$DIR"/tasks/*/plan-review.md >/dev/null 2>&1; then
      if ! find "$DIR"/tasks/*/plan-review.md -newer "$STATE_FILE" 2>/dev/null | grep -q .; then
        block "claudehut-plan-reviewer returned without a fresh verdict. Write the coverage table + APPROVE/REVISE to .claude/claudehut/tasks/<id>/plan-review.md before returning, then the main thread records claudehut-state set-plan-review."
      fi
    fi
    ;;
  claudehut-learner)
    # P1-1 FIX (defense-in-depth): the learner's contract is now to EXTRACT candidates — it writes
    # tasks/<id>/learn-candidates.jsonl, and capture-learnings runs merge-learnings.sh on that to write
    # learnings.jsonl (so the learner no longer touches learnings.jsonl directly). Verify the learner
    # produced a candidates file this session. Proxy for "this session": the state file is created by
    # bootstrap.sh at SessionStart, before any subagent is dispatched — a candidates file newer than it
    # was written this task. Fails open when session_id or state file is absent, or no candidates file
    # exists at all (the inline small-tier path writes none) — never wedge on unexpected state (06 §5).
    sid_l="$(jq -r '.session_id // empty' <<<"$in" 2>/dev/null || true)"
    STATE_FILE="$DIR/state/$sid_l.json"
    if [ -n "$sid_l" ] && [ -f "$STATE_FILE" ] && ls "$DIR"/tasks/*/learn-candidates.jsonl >/dev/null 2>&1; then
      if ! find "$DIR"/tasks/*/learn-candidates.jsonl -newer "$STATE_FILE" 2>/dev/null | grep -q .; then
        block "claudehut-learner returned but no learn-candidates.jsonl was written this session. Extract at least one candidate to .claude/claudehut/tasks/<id>/learn-candidates.jsonl before returning."
      fi
    fi
    # If state file or candidates file absent: fail open (bootstrap may not have run, or first task)
    ;;
  *)
    : # text-returning agents (explorer, brainstormer, auditors) — no file contract to check
    ;;
esac
exit 0
