#!/usr/bin/env bash
# SubagentStop hook, ASYNC, no matcher — dispatch ledger, stop half. LEDGER ONLY (ADR-H5, 04 §5).
#
# v0.11 blocked a returning planner / reuse-scanner / plan-reviewer / learner that had not written its
# artifact (`decision:block`). That contract is gone: artifacts are checked by the `claudehut-state set-*`
# verbs on the main thread, and SubagentStop does not fire for background or killed subagents (#82249,
# #92716), so no check may depend on it. What remains is the stop record, joined to the start record on
# agent_id, which is what makes wall duration derivable for cost-report.
#
# No matcher: matchers are skipped for internal agents (#87065), and those arrive with an EMPTY agent_type.
# They are dropped here (v0.11 recorded them as orphan stops; cost-report discards unmatched stops anyway).
# A teammate's agent_type is its chosen name; lib/resolve-agent.sh maps it back to the claudehut:* type.
#
# Measured SubagentStop key set (Claude Code 2.1.234): agent_id, agent_transcript_path, agent_type,
# background_tasks, cwd, effort, hook_event_name, last_assistant_message, permission_mode, prompt_id,
# session_crons, session_id, stop_hook_active, transcript_path. `.effort` is an object ({"level":"xhigh"});
# the type switch plus `tostring` before every slice keep one shape change (an object where a string was, a
# number such as {"level":3} or "agent_id":7) from throwing in jq and emptying the whole record (V3-C2).

case "$0" in */*) _d="${0%/*}" ;; *) _d="." ;; esac
. "$_d/lib/hook-common.sh" 2>/dev/null || exit 0
. "$_d/lib/resolve-agent.sh" 2>/dev/null || exit 0
hc_init
hc_plane_or_exit

at="$(jq -r '.agent_type // empty' <<<"$HC_IN")"
[ -n "$at" ] || exit 0
resolve_agent "$at" "$HC_SID"

mkdir -p "$PLANE/ledger"
line="$(jq -c --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg rt "$RA_TYPE" --argjson tm "$RA_TEAMMATE" '{
  ts: $t, event: "stop",
  session_id:    (((.session_id // "") | tostring)[0:128]),
  agent_id:      (((.agent_id // "") | tostring)[0:128]),
  agent_type:    (((.agent_type // "") | tostring)[0:128]),
  resolved_type: ($rt[0:128]),
  teammate:      $tm,
  effort:        ((if (.effort|type) == "object" then ((.effort.level // "") | tostring)
                   elif (.effort|type) == "string" then .effort
                   else "" end)[0:32]),
  agent_transcript_path: (((.agent_transcript_path // "") | tostring)[0:512])
}' <<<"$HC_IN")"
[ -n "$line" ] && printf '%s\n' "$line" >> "$PLANE/ledger/dispatches.jsonl"
exit 0
