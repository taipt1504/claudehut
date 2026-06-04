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
  *)
    : # text-returning agents (explorer, brainstormer, auditors, learner) — no file contract to check
    ;;
esac
exit 0
