#!/usr/bin/env bash
# PreToolUse(Agent), SYNC (timeout 5 s) — dispatch identity recorder (PLUMB-F-02/F-06, F-1, ADR-R4).
#
# SubagentStart does not carry the requested subagent_type, and for a teammate dispatch (the Agent call has
# `name`) it reports the chosen name as agent_type. The Agent call carries both, plus the tool_use_id. This
# records name ↔ subagent_type so lib/resolve-agent.sh can join a teammate back to its real type.
#
# SYNC on purpose (HC2-3, 05 §4 note ³): it is the only writer of the ledger that record-dispatch reads on
# SubagentStart. An async PreToolUse does not hold the Agent tool, so the subagent could start (and resolve its
# name) before this row lands. Never a decision: it emits nothing. The append is one short printf so concurrent dispatches
# of a fan-out cannot interleave (fields are capped to keep the record inside one buffered write).
# Sidecar: .claude/claudehut/state/<sid>.agent-dispatch.jsonl

case "$0" in */*) _d="${0%/*}" ;; *) _d="." ;; esac
. "$_d/lib/hook-common.sh" 2>/dev/null || exit 0
hc_init
hc_plane_or_exit
[ -n "$HC_SID" ] || exit 0

line="$(jq -c --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
  select((.tool_input.subagent_type // "") != "")
  | {ts: $t,
     subagent_type: ((.tool_input.subagent_type | tostring)[0:128]),
     name:          (((.tool_input.name // "") | tostring)[0:128]),
     tool_use_id:   (((.tool_use_id // "") | tostring)[0:128])}' <<<"$HC_IN")"
[ -n "$line" ] && printf '%s\n' "$line" >> "$PLANE/state/$HC_SID.agent-dispatch.jsonl"
exit 0
