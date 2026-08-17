#!/usr/bin/env bash
# PreCompact hook. Copies the live per-session state file to state/<sid>.snapshot.json.
#
# W20 (v0.12) — WHAT THIS ACTUALLY PROTECTS, corrected. The old header claimed "durability before context
# compaction … so a long session that compacts mid-task does not lose phase position." It does not do that.
# Compaction never loses the state file: a compact/resume keeps the SAME session_id, so state/<sid>.json
# survives untouched — bootstrap.sh:54-55 concedes exactly that in its own comment. And the snapshot's only
# consumer, bootstrap.sh:58, restores it ONLY when the live file is MISSING. So on the compaction path this
# snapshot is written and never read.
# What it IS: crash insurance whose TRIGGER happens to be a compaction. When the live state file disappears
# for a reason unrelated to compacting — crash, manual cleanup, a stray rm — the next SessionStart restores
# this snapshot instead of re-arming at phase=discover, which would reset the phase and close the skill rail
# mid-task. That path is real and tested (gate-tests.sh deletes the live file and asserts the restore), which
# is why the hook stays. Two consequences worth stating rather than leaving implied: the snapshot is only ever
# as fresh as the last compaction, so a session that never compacts has no insurance at all; and this is not
# the compaction-durability mechanism the old header advertised, so do not reach for it as one.
#
# Runs synchronously (hooks.json timeout) so the copy completes before compaction. See 06 §3 / 07 §5.
set -euo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
in="$(cat || true)"
command -v jq >/dev/null 2>&1 || exit 0

DIR="$PROJECT_DIR/.claude/claudehut"

# W21 — MEASURED, not assumed any more. PreCompact used to be the one hooked event with no payload capture,
# so the `.session_id` read below was a guess whose failure mode is silent and total: sid empty -> STATE
# becomes "<dir>/state/.json" -> the [ -f ] test fails -> the hook exits 0 having copied nothing, which is
# byte-identical to success. This block is the mechanism that answered it (same flag and same shape as
# bootstrap.sh:33-36 and record-failure.sh:19-27, which produced v0.11's two payload findings), and one real
# manual compaction on Claude Code 2.1.234 gave the COMPLETE key set:
#   custom_instructions  cwd  hook_event_name  prompt_id  session_id  transcript_path  trigger
# `.session_id` IS present and matches the live session, and `.trigger` is "manual" on a `/compact`. So the
# read below is correct as written. The block stays because the key set is the runtime's to change, and
# because `trigger` ("manual" vs the auto path) is the one field here nothing reads yet.
# Placed BEFORE any field is read, because .session_id was itself the guess. `|| true` on every line: this
# file runs `set -euo pipefail` at the top and a debug aid must never take the hook down. Off by default.
if [ "${CLAUDEHUT_DEBUG_PAYLOAD:-}" = "1" ]; then
  mkdir -p "$DIR/state" 2>/dev/null \
    && printf '%s\n' "$in" >> "$DIR/state/payload-debug.PreCompact.jsonl" 2>/dev/null || true
fi

sid="$(jq -r '.session_id // empty' <<<"$in" 2>/dev/null || true)"

# Note: learnings.staged.jsonl had no producer anywhere in the plugin — the flush was
# dead code (always a no-op) and is removed. claudehut-learner writes learnings.jsonl
# directly in the Learn phase; there is no mid-task staging to flush here.

# Snapshot the per-session state file.
STATE="$DIR/state/$sid.json"
[ -f "$STATE" ] && cp -f "$STATE" "$DIR/state/$sid.snapshot.json" 2>/dev/null || true

exit 0
