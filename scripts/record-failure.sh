#!/usr/bin/env bash
# PostToolUseFailure hook (matcher: Bash) — failure SIGNAL capture (audit C.3).
#
# Stages failed Bash commands (build/test errors) to a SESSION-SCOPED, ephemeral file so the
# Learn phase has real failure signal to curate. It does NOT write the permanent learnings.jsonl
# directly: many Bash failures are intentional (TDD RED runs, expected non-zero exits), so
# auto-promoting them would pollute the curated store. The learner reads this staging file and
# decides what is a genuine, reusable lesson. Non-blocking (the tool already failed); always exit 0.
#
# Staging file: .claude/claudehut/state/<sid>.failures.jsonl  (under state/ = gitignored/ephemeral).
set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
in="$(cat || true)"
command -v jq >/dev/null 2>&1 || exit 0

# W0-B (v0.11): every field this script reads except .tool_input.command comes back EMPTY in production —
# measured 682/682 records with empty type+exit+stderr across the real repos. The field paths below were
# guessed, and guessing a second set would repeat the bug. So: with CLAUDEHUT_DEBUG_PAYLOAD=1, append the
# RAW payload before any field is read or any early-exit fires, so the real key names can be read off a
# real event. Off by default; costs nothing when unset. Deliberately not session-scoped — .session_id is
# itself one of the guesses, and a wrong guess there would silently produce no file at all.
if [ "${CLAUDEHUT_DEBUG_PAYLOAD:-}" = "1" ]; then
  _dbg="$PROJECT_DIR/.claude/claudehut/state"
  mkdir -p "$_dbg" 2>/dev/null \
    && printf '%s\n' "$in" >> "$_dbg/payload-debug.PostToolUseFailure.jsonl" 2>/dev/null || true
fi

sid="$(jq -r '.session_id // empty' <<<"$in" 2>/dev/null || true)"
tool="$(jq -r '.tool_name // empty' <<<"$in" 2>/dev/null || true)"
[ -n "$sid" ] && [ "$tool" = "Bash" ] || exit 0

cmd="$(jq -r '.tool_input.command // empty' <<<"$in" 2>/dev/null || true)"
code="$(jq -r '.tool_error.exit_code // empty' <<<"$in" 2>/dev/null || true)"
etype="$(jq -r '.tool_error.type // empty' <<<"$in" 2>/dev/null || true)"
# keep only a short tail of stderr — enough to fingerprint the failure, not a wall of logs
err="$(jq -r '.tool_error.stderr // empty' <<<"$in" 2>/dev/null | tail -c 600 || true)"
[ -n "$cmd" ] || exit 0

DIR="$PROJECT_DIR/.claude/claudehut/state"
mkdir -p "$DIR" 2>/dev/null || exit 0
F="$DIR/$sid.failures.jsonl"

# dedup: skip if the immediately-previous entry has the same command + exit (repeated identical failure)
if [ -f "$F" ]; then
  prev="$(tail -1 "$F" 2>/dev/null | jq -r '"\(.command)\u0000\(.exit)"' 2>/dev/null || true)"
  this="$(printf '%s\000%s' "$cmd" "$code")"
  [ "$prev" = "$this" ] && exit 0
fi

# W0-B (v0.11): when ALL THREE known error paths come back empty, the schema this script was written
# against is not the schema being sent (measured: 682/682 production records, empty type+exit+stderr).
# Record the payload's top-level KEY NAMES so the next real failure names the right fields by itself,
# without a debug env var having been set in advance. Names only, never values — a payload carries
# command text and environment detail that must not be appended to a staged file. Capped at 200 chars,
# as record-rules-loaded.sh caps its fields. Emitted ONLY on the empty case, so a healthy payload
# produces a byte-identical record and nothing downstream sees a new field.
keys=""
if [ -z "$code" ] && [ -z "$etype" ] && [ -z "$err" ]; then
  keys="$(jq -r 'keys_unsorted | join(",")' <<<"$in" 2>/dev/null || true)"
  keys="${keys:0:200}"
fi

line="$(jq -nc --arg c "$cmd" --arg code "$code" --arg t "$etype" --arg e "$err" --arg k "$keys" \
  '{command:$c, exit:$code, type:$t, stderr:$e}
   + (if $k == "" then {} else {schema_keys:$k} end)' 2>/dev/null || true)"
[ -n "$line" ] && printf '%s\n' "$line" >> "$F"

# cap at the last 20 failures so the staging file can't grow without bound
if [ "$(wc -l < "$F" 2>/dev/null || echo 0)" -gt 20 ]; then
  tmp="$(mktemp "$DIR/.fail.XXXXXX")" && tail -20 "$F" > "$tmp" && mv -f "$tmp" "$F" 2>/dev/null || true
fi
exit 0
