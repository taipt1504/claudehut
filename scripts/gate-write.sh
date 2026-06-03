#!/usr/bin/env bash
# PreToolUse hook (matcher: Write|Edit|MultiEdit) — the ACTION GATE.
# Denies new production code until: reuse_scan=true AND spec_path set AND plan_path set.
# Always allows: writes under .claude/claudehut/**, test paths, and when bypass=true.
# Per-session state keyed by hook-input session_id. FAILS OPEN on a missing state file
# (allows) — deliberate, never wedge the user; see 06 §5 / 01 §4.1.
set -euo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
in="$(cat || true)"
command -v jq >/dev/null 2>&1 || exit 0   # degrade: fail open

allow() { exit 0; }   # no decision = proceed normally
deny()  { jq -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r,additionalContext:$r}}'; exit 0; }

fp="$(jq -r '.tool_input.file_path // empty' <<<"$in" 2>/dev/null || true)"
sid="$(jq -r '.session_id // empty' <<<"$in" 2>/dev/null || true)"

# Non-production targets are always allowed (reuse-scan/spec/plan files; tests during TDD RED).
case "$fp" in
  *"/.claude/claudehut/"*|*"/test/"*|*Test.java|*IT.java) allow ;;
esac

STATE="$PROJECT_DIR/.claude/claudehut/state/$sid.json"
[ -f "$STATE" ] || allow   # no active workflow for this session → fail open (06 §5)
s="$(cat "$STATE" 2>/dev/null || echo '{}')"

[ "$(jq -r '.bypass // false' <<<"$s")" = "true" ] && allow

reuse="$(jq -r '.reuse_scan // false' <<<"$s")"
art="$(jq -r '.reuse_scan_artifact // empty' <<<"$s")"
spec="$(jq -r '.spec_path // empty' <<<"$s")"
plan="$(jq -r '.plan_path // empty' <<<"$s")"

# opt #4: a recorded artifact must actually EXIST as a file under .claude/claudehut/ — a set flag
# pointing at a missing or non-canonical path does NOT open the gate.
exists_canon() {
  local p="$1"; [ -n "$p" ] && [ "$p" != null ] || return 1
  case "$p" in /*) : ;; *) p="$PROJECT_DIR/$p" ;; esac
  case "$p" in *"/.claude/claudehut/"*) [ -f "$p" ] && return 0 ;; esac
  return 1
}

if [ "$reuse" != "true" ]; then
  deny "ClaudeHut gate: run claudehut:brainstorm first (its reuse-scan step) — no reuse-scan artifact for this task (think-and-reuse before build)."
elif ! exists_canon "$art"; then
  deny "ClaudeHut gate: reuse-scan flag set but no artifact file under .claude/claudehut/ (got: ${art:-none}). Write the reuse-scan there."
elif [ -z "$spec" ] || [ "$spec" = "null" ]; then
  deny "ClaudeHut gate: write the implementation spec first — run claudehut:write-spec."
elif ! exists_canon "$spec"; then
  deny "ClaudeHut gate: spec recorded but file not found under .claude/claudehut/ (got: $spec). Write it in the task dir .claude/claudehut/tasks/NNNN-<slug>/spec.md, not a bare specs/ path."
elif [ -z "$plan" ] || [ "$plan" = "null" ]; then
  deny "ClaudeHut gate: write the plan first — run claudehut:write-plan."
elif ! exists_canon "$plan"; then
  deny "ClaudeHut gate: plan recorded but file not found under .claude/claudehut/ (got: $plan). Write it in the task dir .claude/claudehut/tasks/NNNN-<slug>/plan.md."
fi
allow
