#!/usr/bin/env bash
# PreToolUse(Agent) — dispatch IDENTITY recorder (PLUMB-F-02 / PLUMB-F-06).
#
# SubagentStart tells us a subagent started; it does not carry the requested `subagent_type`, so
# record-dispatch.sh could log that *something* was dispatched but not *what*. The Agent tool call itself
# does carry it, in `tool_input.subagent_type`, along with a `tool_use_id` that both sides share. This hook
# records the identity half; the join key is the tool_use_id.
#
# NEVER BLOCKS. This runs on PreToolUse, which is the one event that can deny a tool call, and it sits in
# front of every fan-out in the workflow. A recorder that can return a deny decision is a new way to break
# parallel dispatch, so this exits 0 on every path and emits no JSON at all.
set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
in="$(cat || true)"
command -v jq >/dev/null 2>&1 || exit 0

sid="$(jq -r '.session_id // empty' <<<"$in" 2>/dev/null || true)"
[ -n "$sid" ] || exit 0
sub="$(jq -r '.tool_input.subagent_type // empty' <<<"$in" 2>/dev/null || true)"
tuid="$(jq -r '.tool_use_id // empty' <<<"$in" 2>/dev/null || true)"
[ -n "$sub" ] || exit 0

DIR="$PROJECT_DIR/.claude/claudehut/state"
mkdir -p "$DIR" 2>/dev/null || exit 0

# Capped for the same reason record-dispatch.sh caps: the append must stay inside one buffered write so
# concurrent dispatches — the normal case here — cannot interleave. No lock on a pre-dispatch hook.
sub="${sub:0:128}"; tuid="${tuid:0:128}"
line="$(jq -nc --arg a "$sub" --arg u "$tuid" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{ts:$t, subagent_type:$a, tool_use_id:$u}' 2>/dev/null || true)"
[ -n "$line" ] && printf '%s\n' "$line" >> "$DIR/$sid.agent-dispatch.jsonl" 2>/dev/null

exit 0
