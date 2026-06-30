#!/usr/bin/env bash
# Stop hook — the COMPLETION GATE.
# Blocks turn end until review=pass AND phase=learn. Honors the native consecutive-Stop
# cap: when stop_hook_active is true (~8 blocks reached) it stops blocking and surfaces the
# remaining outstanding items, instead of wedging the session. Per-session state by
# hook-input session_id. FAILS OPEN on missing state. See 06 §3 / 01 §8.
set -euo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
in="$(cat || true)"
command -v jq >/dev/null 2>&1 || exit 0   # degrade: fail open

block() { jq -n --arg r "$1" '{decision:"block",reason:$r}'; exit 0; }

# Native cap: never block past the consecutive-Stop limit.
[ "$(jq -r '.stop_hook_active // false' <<<"$in" 2>/dev/null || echo false)" = "true" ] && exit 0

# PARK-and-wait fail-open: a Stop fired while a background subagent is STILL RUNNING is not a
# completion attempt — the main thread merely ended its turn to await background Agent/Task results
# (e.g. the Review fan-out). Blocking it spams "Stop hook error" on every background-agent completion
# (the measured 0012 symptom). No documented Stop-hook field exposes background tasks (confirmed against
# the CC hooks docs), so detect via the transcript: a FOREGROUND subagent always completes (its
# tool_result is paired) before the main turn ends; a background one still in flight leaves its
# Agent/Task tool_use UNPAIRED. Any unpaired ⇒ parked ⇒ fail open. Streaming (memory = #ids, not file
# size). Fails open on missing/unreadable transcript → no behavior change when absent (e.g. under test).
tp="$(jq -r '.transcript_path // empty' <<<"$in" 2>/dev/null || true)"
if [ -n "$tp" ] && [ -f "$tp" ]; then
  pend="$(jq -n '
    (reduce inputs as $x ({u:[],r:[]};
       if   ($x.type=="assistant") then .u += [ $x.message.content[]? | select(.type=="tool_use"    and (.name=="Agent" or .name=="Task")) | .id ]
       elif ($x.type=="user")      then .r += [ $x.message.content[]? | select(.type=="tool_result") | .tool_use_id ]
       else . end)) as $s
    | [ $s.u[] | . as $id | select( ($s.r | index($id)) == null ) ] | length' < "$tp" 2>/dev/null || echo 0)"
  case "$pend" in ''|*[!0-9]*) pend=0 ;; esac
  [ "$pend" -gt 0 ] && exit 0   # background subagent(s) still running → parked, not finishing
fi

sid="$(jq -r '.session_id // empty' <<<"$in" 2>/dev/null || true)"
STATE="$PROJECT_DIR/.claude/claudehut/state/$sid.json"
[ -f "$STATE" ] || exit 0   # no active workflow for this session → don't block stop (06 §5)
s="$(cat "$STATE" 2>/dev/null || echo '{}')"
jq -e . <<<"$s" >/dev/null 2>&1 || s='{}'   # N4: a corrupt state file → treat as empty (fail open, no jq noise)

[ "$(jq -r '.bypass // false' <<<"$s")" = "true" ] && exit 0

review="$(jq -r '.review // "pending"' <<<"$s")"
phase="$(jq -r '.phase // "discover"' <<<"$s")"
reuse="$(jq -r '.reuse_scan // false' <<<"$s")"
spec="$(jq -r '.spec_path // empty' <<<"$s")"
plan="$(jq -r '.plan_path // empty' <<<"$s")"
tier="$(jq -r '.complexity // "full"' <<<"$s")"   # trivial skips Learn (tier map) — gate must match
profile="$(jq -r '.profile // empty' <<<"$s")"     # WS-7 task shape — decides the deliverable rail

# opt #1: the SessionStart hook ARMS state (phase=discover) so the write gate denies production
# writes from turn 1. But only enforce COMPLETION once the workflow was actually ENGAGED — a freshly
# armed session that never did workflow work (no reuse-scan, no spec/plan, still discover/brainstorm) must not
# block turn end, so non-coding sessions stay usable. Writing production code requires engaging the
# workflow (the write gate forces it), and once engaged this gate requires it to finish.
engaged=false
{ [ "$reuse" = "true" ] \
  || { [ -n "$spec" ] && [ "$spec" != null ]; } \
  || { [ -n "$plan" ] && [ "$plan" != null ]; } \
  || [ "$phase" = plan ] || [ "$phase" = implement ] || [ "$phase" = review ] || [ "$phase" = learn ] \
  || [ "$profile" = audit ] || [ "$profile" = investigation ]; } && engaged=true   # WS-7 M2: declaring an audit/investigation shape IS engagement (a pure audit may never set reuse-scan or advance past discover)
[ "$engaged" = true ] || exit 0

# WS-7: audit/investigation produce a FINDINGS deliverable, not production code — so the code-review gate
# (review==pass) does not apply. Completion requires a findings.md artifact (the profile-aware deliverable
# rail) plus, on a non-trivial tier, the universal Learn pass. This is the genuine adaptivity: the same
# "done" gate MEANS something different per task shape, not just a different label.
if [ "$profile" = "audit" ] || [ "$profile" = "investigation" ]; then
  # WS-7 M1: check THIS task's RECORDED findings (set-findings), not a glob that any prior task satisfies.
  fp="$(jq -r '.findings_path // empty' <<<"$s")"
  fok=false
  if [ -n "$fp" ] && [ "$fp" != null ]; then
    case "$fp" in /*) fpp="$fp" ;; *) fpp="$PROJECT_DIR/$fp" ;; esac
    [ -f "$fpp" ] && fok=true
  fi
  if [ "$fok" != true ]; then
    block "ClaudeHut gate: profile=$profile — the deliverable is a findings report, not code. Write the audit's conclusions + file:line evidence to tasks/NNNN-<slug>/findings.md and record it: claudehut-state set-findings <that path>."
  fi
  if [ "$tier" != "trivial" ]; then
    RECEIPT="$PROJECT_DIR/.claude/claudehut/state/$sid.learn-receipt.json"
    [ -f "$RECEIPT" ] || block "ClaudeHut gate: findings produced but no learn-receipt this session — run claudehut:capture-learnings before finishing."
  fi
  exit 0
fi

if [ "$review" != "pass" ]; then
  block "ClaudeHut gate: Review not passed — run claudehut:review until the outstanding set is empty, with fresh evidence."
elif [ "$tier" != "trivial" ] && [ "$phase" != "learn" ]; then
  # trivial tier legitimately skips Learn (workflow tier map) — blocking it here would wedge the
  # session until the consecutive-Stop cap. full + small still require the Learn pass.
  block "ClaudeHut gate: Learn pass not run — run claudehut:capture-learnings before finishing."
elif [ "$tier" != "trivial" ] && [ "$phase" = "learn" ]; then
  # WS-6: phase=learn is necessary but not sufficient. The fictional old check ("learnings.jsonl non-empty")
  # passed on ANY prior line. The real proof a Learn pass ran THIS task is a per-session learn-receipt
  # (written by merge-learnings / the inline learn path) NEWER than this task's reuse-scan (the first artifact
  # every task produces in Discover). Fail-open: if the reuse-scan path is unavailable, require only that the
  # receipt exists — never wedge on unexpected state.
  RECEIPT="$PROJECT_DIR/.claude/claudehut/state/$sid.learn-receipt.json"
  if [ ! -f "$RECEIPT" ]; then
    block "ClaudeHut gate: no learn-receipt for this session — capture-learnings did not run its merge this task. Run claudehut:capture-learnings before finishing."
  else
    art="$(jq -r '.reuse_scan_artifact // empty' <<<"$s")"
    if [ -n "$art" ] && [ "$art" != null ]; then
      case "$art" in /*) artp="$art" ;; *) artp="$PROJECT_DIR/$art" ;; esac
      if [ -f "$artp" ] && [ "$artp" -nt "$RECEIPT" ]; then
        block "ClaudeHut gate: the learn-receipt is stale (older than this task's reuse-scan) — Learn ran for a PRIOR task, not this one. Re-run claudehut:capture-learnings for the current task."
      fi
    fi
  fi
fi
exit 0
