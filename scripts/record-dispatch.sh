#!/usr/bin/env bash
# SubagentStart hook, SYNC (timeout 5 s) — dispatch ledger, start half (F5, F-1).
#
# Appends one record to .claude/claudehut/ledger/dispatches.jsonl (shared, append-only, never swept;
# session_id is a field). agent_type is resolved through lib/resolve-agent.sh: a teammate reports its chosen
# name, which the PreToolUse(Agent) ledger maps back to the claudehut:* subagent_type.
#
# Output: one line, and only for a claudehut-implementer running as a teammate. A teammate ignores the
# agent's `skills:` preload, so it would start without the implement skill; the line points it at the file.
# Sync on purpose — an async hook's output arrives a turn later, after the subagent already started.
#
# Measured SubagentStart key set (Claude Code 2.1.234): agent_id, agent_type, cwd, hook_event_name,
# prompt_id, session_id, transcript_path. `effort` exists only on SubagentStop, so it is not recorded here.

case "$0" in */*) _d="${0%/*}" ;; *) _d="." ;; esac
. "$_d/lib/hook-common.sh" 2>/dev/null || exit 0
. "$_d/lib/resolve-agent.sh" 2>/dev/null || exit 0
hc_init
hc_plane_or_exit
[ -n "$HC_SID" ] || exit 0

at="$(jq -r '.agent_type // empty' <<<"$HC_IN")"
resolve_agent "$at" "$HC_SID"

# PROJECT_DIR, never the payload's .cwd: a worktree subagent runs elsewhere, and rooting the ledger there
# would split its start and stop records across two files.
mkdir -p "$PLANE/ledger"
line="$(jq -c --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg rt "$RA_TYPE" --argjson tm "$RA_TEAMMATE" '{
  ts: $t, event: "start",
  session_id:    (((.session_id // "") | tostring)[0:128]),
  agent_id:      (((.agent_id // "") | tostring)[0:128]),
  agent_type:    (((.agent_type // "") | tostring)[0:128]),
  resolved_type: ($rt[0:128]),
  teammate:      $tm,
  cwd:           (((.cwd // "") | tostring)[0:512])
}' <<<"$HC_IN")"
[ -n "$line" ] && printf '%s\n' "$line" >> "$PLANE/ledger/dispatches.jsonl"

if [ "$RA_TEAMMATE" = "true" ] && [ "$RA_TYPE" = "claudehut:claudehut-implementer" ]; then
  PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$_d/.." 2>/dev/null && pwd)}"
  hc_ctx SubagentStart "This implementer runs as a teammate, so its skills preload did not apply. The implement skill is at $PLUGIN_ROOT/skills/implement/SKILL.md."
fi
exit 0
