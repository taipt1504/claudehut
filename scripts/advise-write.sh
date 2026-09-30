#!/usr/bin/env bash
# PreToolUse hook (matcher: Write|Edit|NotebookEdit) — ADVISORY, never a gate (05 §3, ADR-H2, ADR-R3).
#
# Replaces v0.11 gate-write.sh, whose deny path did more harm than good: Bash still wrote src/main (70
# commands, B8), the fast lane counted the whole dirty working tree (343 files, core-ledger 2e70d1d8, A1/B5),
# and an armed-by-default state denied scratchpad and .understand-anything/ writes in sessions that were not
# doing workflow work at all (report-service 652fab55, A9).
#
# Speaks only when the full predicate holds, and then once per task:
#   plane ∧ active task (schema 2) ∧ route=full ∧ plan_approved=false ∧ path ∈ task.scope ∧ not yet nudged
# Every other path — no plane, no task, v0.11 state, light route, approved plan, out-of-scope path — is
# exit 0 with empty stdout. The tool call proceeds in every branch; there is no decision field to emit.

case "$0" in */*) _d="${0%/*}" ;; *) _d="." ;; esac
. "$_d/lib/hook-common.sh" 2>/dev/null || exit 0
hc_init
hc_plane_or_exit
hc_active_task || exit 0                       # cheapest negative first: no task → no path parsing at all

read -r route approved <<<"$(jq -r '"\(.route // "") \(.plan_approved // false)"' <<<"$HC_TASK")"
[ "$route" = "full" ] && [ "$approved" != "true" ] || exit 0

fp="$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"$HC_IN")"
hc_rel "$fp" || exit 0
hc_in_scope "$HC_REL" || exit 0
hc_once "advise-write:$HC_TASK_ID" || exit 0

# A long path is shortened from the left (bytes, on a UTF-8 boundary) so the 500-char cap never cuts the fixed text.
tail_cut() { # last $1 bytes of HC_REL, not starting inside a UTF-8 sequence
  local LC_ALL=C
  local r="${HC_REL: -$1}"
  while :; do case "${r:0:1}" in [$'\x80'-$'\xbf']) r="${r:1}" ;; *) break ;; esac; done
  printf '%s' "$r"
}
rel="$HC_REL"; [ "${#rel}" -le 110 ] || rel="…$(tail_cut 110)"
hc_ctx PreToolUse "ClaudeHut: task $HC_TASK_ID is on the full route and its plan is not approved yet (plan_approved=false); $rel is inside the task scope. The full route records the approved plan with claudehut-state set-plan before production edits. This edit is not blocked; this note appears once per task."
exit 0
