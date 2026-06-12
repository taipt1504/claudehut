#!/usr/bin/env bash
# PreCompact hook. Durability before context compaction: snapshot the per-session
# state file so a long session that compacts mid-task does not lose phase position.
# Runs synchronously (hooks.json timeout) so the snapshot completes before compaction.
# See 06 §3 / 07 §5.
set -euo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
in="$(cat || true)"
command -v jq >/dev/null 2>&1 || exit 0

DIR="$PROJECT_DIR/.claude/claudehut"
sid="$(jq -r '.session_id // empty' <<<"$in" 2>/dev/null || true)"

# Note: learnings.staged.jsonl had no producer anywhere in the plugin — the flush was
# dead code (always a no-op) and is removed. claudehut-learner writes learnings.jsonl
# directly in the Learn phase; there is no mid-task staging to flush here.

# Snapshot the per-session state file.
STATE="$DIR/state/$sid.json"
[ -f "$STATE" ] && cp -f "$STATE" "$DIR/state/$sid.snapshot.json" 2>/dev/null || true

exit 0
