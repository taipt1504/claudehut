#!/usr/bin/env bash
# PreCompact hook (async). Best-effort durability before context compaction:
# flush any staged learnings into learnings.jsonl and snapshot the per-session state file,
# so a long session that compacts mid-task does not lose phase position or learnings.
# Non-blocking; relies on the agent having staged learnings. See 06 §3 / 07 §5.
set -euo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
in="$(cat || true)"
command -v jq >/dev/null 2>&1 || exit 0

DIR="$PROJECT_DIR/.claude/claudehut"
sid="$(jq -r '.session_id // empty' <<<"$in" 2>/dev/null || true)"

# Flush staged learnings (one JSON object per line) into the durable store.
STAGED="$DIR/learnings.staged.jsonl"
if [ -f "$STAGED" ]; then
  cat "$STAGED" >> "$DIR/learnings.jsonl" 2>/dev/null || true
  : > "$STAGED" || true
fi

# Snapshot the per-session state file.
STATE="$DIR/state/$sid.json"
[ -f "$STATE" ] && cp -f "$STATE" "$DIR/state/$sid.snapshot.json" 2>/dev/null || true

exit 0
