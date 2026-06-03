#!/usr/bin/env bash
# Stop hook — the COMPLETION GATE.
# Blocks turn end until review=pass AND phase=learn. Honors the native consecutive-Stop
# cap: when stop_hook_active is true (~8 blocks reached) it stops blocking and surfaces the
# remaining outstanding items, instead of wedging the session. Per-session state by
# hook-input session_id. FAILS OPEN on missing state. See 06 §3 / 01 §8.
set -euo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
in="$(cat || true)"
command -v jq >/dev/null 2>&1 || exit 0   # degrade: fail open

block() { jq -n --arg r "$1" '{decision:"block",reason:$r}'; exit 0; }

# Native cap: never block past the consecutive-Stop limit.
[ "$(jq -r '.stop_hook_active // false' <<<"$in" 2>/dev/null || echo false)" = "true" ] && exit 0

sid="$(jq -r '.session_id // empty' <<<"$in" 2>/dev/null || true)"
STATE="$PROJECT_DIR/.claude/claudehut/state/$sid.json"
[ -f "$STATE" ] || exit 0   # no active workflow for this session → don't block stop (06 §5)
s="$(cat "$STATE" 2>/dev/null || echo '{}')"

[ "$(jq -r '.bypass // false' <<<"$s")" = "true" ] && exit 0

review="$(jq -r '.review // "pending"' <<<"$s")"
phase="$(jq -r '.phase // "brainstorm"' <<<"$s")"
reuse="$(jq -r '.reuse_scan // false' <<<"$s")"
spec="$(jq -r '.spec_path // empty' <<<"$s")"
plan="$(jq -r '.plan_path // empty' <<<"$s")"

# opt #1: the SessionStart hook ARMS state (phase=brainstorm) so the write gate denies production
# writes from turn 1. But only enforce COMPLETION once the workflow was actually ENGAGED — a freshly
# armed session that never did workflow work (no reuse-scan, no spec/plan, still brainstorm) must not
# block turn end, so non-coding sessions stay usable. Writing production code requires engaging the
# workflow (the write gate forces it), and once engaged this gate requires it to finish.
engaged=false
{ [ "$reuse" = "true" ] \
  || { [ -n "$spec" ] && [ "$spec" != null ]; } \
  || { [ -n "$plan" ] && [ "$plan" != null ]; } \
  || [ "$phase" = plan ] || [ "$phase" = implement ] || [ "$phase" = review ] || [ "$phase" = learn ]; } && engaged=true
[ "$engaged" = true ] || exit 0

if [ "$review" != "pass" ]; then
  block "ClaudeHut gate: Review not passed — run claudehut:review until the outstanding set is empty, with fresh evidence."
elif [ "$phase" != "learn" ]; then
  block "ClaudeHut gate: Learn pass not run — run claudehut:capture-learnings before finishing."
fi
exit 0
