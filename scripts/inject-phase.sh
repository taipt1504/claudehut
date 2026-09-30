#!/usr/bin/env bash
# UserPromptSubmit hook — prompt-relevant learnings for turns a person typed (05 §4 #3, 04 §4, ADR-R4).
#
# v0.12 removed the phase line, the Phase-0 triage block, "Untriaged" and the discover default (A10): with no
# task there is no phase to anchor, and a question is not an untriaged task. What is left is a small learnings
# block (top 3, ≤500 chars).
#
# Machine-generated turns get nothing: task-notifications, teammate / agent messages and cross-session
# messages open a turn of their own and used to receive the same injection (51% of all UPS bytes, F-6). The
# filter is a superset of the two prefixes measured on ewallet transcripts plus <agent-message; if the format
# changes the cost is an extra injection, never a missing one on a human turn.

case "$0" in */*) _d="${0%/*}" ;; *) _d="." ;; esac
. "$_d/lib/hook-common.sh" 2>/dev/null || exit 0
hc_init
hc_plane_or_exit

prompt="$(jq -r '.prompt // empty' <<<"$HC_IN")"
[ -n "$prompt" ] || exit 0
MACHINE_RE='^[[:space:]]*(<\\?(teammate-message|task-notification|agent-message)|Another Claude session sent a message)'
[[ $prompt =~ $MACHINE_RE ]] && exit 0

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$_d/.." 2>/dev/null && pwd)}"
[ -x "$PLUGIN_ROOT/scripts/inject-learnings.sh" ] && [ -f "$PLANE/learnings.jsonl" ] || exit 0
[ -n "$HC_SID" ] || exit 0

# The exclude set accumulates per session (LRN-9), so consecutive prompts do not re-pay for the same entries;
# it is also the file merge-learnings reads to stamp `.applied`. A sidecar, not the state JSON (K8).
INJ="$PLANE/state/$HC_SID.injected.json"
learn="$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" "$PLUGIN_ROOT/scripts/inject-learnings.sh" --filter "$prompt" --top 3 --max-len 90 --compact \
         --accumulate "$INJ" 2>/dev/null)" || learn=""

# ≤500 chars (K9): drop body lines from the end rather than truncating, so the untrusted-data closing marker
# written by inject-learnings.sh always survives.
if [ -n "$learn" ]; then
  while [ "${#learn}" -gt 480 ]; do
    head_="${learn%%$'\n'*}"; tail_="${learn##*$'\n'}"
    body="${learn#*$'\n'}"; body="${body%$'\n'*}"
    [ "$body" != "${body%$'\n'*}" ] || { learn=""; break; }   # one line left and still too long: send nothing
    body="${body%$'\n'*}"
    learn="$head_"$'\n'"$body"$'\n'"$tail_"
  done
fi
[ -n "$learn" ] && hc_ctx UserPromptSubmit "Relevant learnings:"$'\n'"$learn"
exit 0
