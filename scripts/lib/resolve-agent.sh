# shellcheck shell=bash
# resolve-agent.sh — join a teammate's self-chosen name back to its subagent_type (04 §5, ADR-R4).
#
# 61% of claudehut dispatches carry `name`, so they run as teammates and SubagentStart/Stop report the
# chosen name ("planner-0099") as agent_type, not "claudehut:claudehut-planner". PreToolUse(Agent)
# (record-agent-dispatch.sh) records name ↔ subagent_type in state/<sid>.agent-dispatch.jsonl; this reads it.
#
# resolve_agent <agent_type> <sid>  → sets RA_TYPE and RA_TEAMMATE (true|false)
#   empty agent_type                     → RA_TYPE=""                    (internal agent, #87065)
#   claudehut:* already                  → unchanged
#   newest ledger row with name==type
#     and a claudehut:* subagent_type    → that subagent_type, RA_TEAMMATE=true
#   anything else                        → unchanged
# Needs PLANE (hook-common.sh). Never fails: a missing or torn ledger just leaves the type unchanged.

resolve_agent() {
  RA_TYPE="$1"; RA_TEAMMATE=false
  [ -n "$RA_TYPE" ] || return 0
  case "$RA_TYPE" in claudehut:*) return 0 ;; esac
  local led="$PLANE/state/$2.agent-dispatch.jsonl" hit
  [ -n "$2" ] && [ -f "$led" ] || return 0
  hit="$(jq -Rr --arg n "$RA_TYPE" 'fromjson? // empty
          | select((.name // "") == $n and ((.subagent_type // "") | startswith("claudehut:")))
          | .subagent_type' "$led" 2>/dev/null | tail -1)" || hit=""
  if [ -n "$hit" ]; then RA_TYPE="$hit"; RA_TEAMMATE=true; fi
  return 0
}
