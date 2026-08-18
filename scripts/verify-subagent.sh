#!/usr/bin/env bash
# SubagentStop hook. Blocks if a file-producing phase subagent returned without its required
# artifact. Default contract (accepted default C3): only agents whose contract is a FILE are
# checked — claudehut-reuse-scanner (tasks/*/reuse-scan.md) and claudehut-planner (tasks/*/plan.md).
# The Review auditors return findings as text (no file) and are not file-checked here.
# Verb name ("verify") — not the retired Verify phase. See 06 §3.
set -euo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
in="$(cat || true)"
command -v jq >/dev/null 2>&1 || exit 0   # degrade: fail open

block() { jq -n --arg r "$1" '{decision:"block",reason:$r}'; exit 0; }

# HANG FIX: a blocking SubagentStop holds the subagent open ("continue working"); without this cap a
# missing/mispathed artifact loops the block forever — an infinite hold that presents as a hang.
# Same native cap gate-done.sh uses: when stop_hook_active is true, stop blocking and fail open.
[ "$(jq -r '.stop_hook_active // false' <<<"$in" 2>/dev/null || echo false)" = "true" ] && exit 0

# ---- F5: dispatch ledger, stop half ------------------------------------------------------------------
# scripts/record-dispatch.sh appends the SubagentStart half to .claude/claudehut/ledger/dispatches.jsonl;
# this appends its counterpart, joined on `agent_id`. Without a stop record the ledger cannot yield wall
# duration, which is the only dispatch cost this plugin can honestly measure (no hook payload carries tokens).
#
# WHY IT IS WRITTEN DEFENSIVELY. This script runs `set -euo pipefail` at :7 and is a BLOCKING SubagentStop
# hook that owns the artifact contract — a failing append would abort the gate, turning an observation
# feature into an enforcement outage. The whole block therefore sits on the left of `|| true`, which
# suppresses errexit inside it, and its stdout is redirected away: four gate-tests assertions are
# `[ -z "$(… | verify-subagent.sh)" ]`, so one stray byte on stdout reads as a false block.
# Placed AFTER the stop_hook_active cap on purpose — re-entrant stops (the block loop) would otherwise
# append a second stop record for one dispatch and break the one-start-one-stop pairing.
#
# FIELDS — measured on Claude Code 2.1.234. The COMPLETE SubagentStop key set is: agent_id,
# agent_transcript_path, agent_type, background_tasks, cwd, effort, hook_event_name, last_assistant_message,
# permission_mode, prompt_id, session_crons, session_id, stop_hook_active, transcript_path. `effort` and
# `agent_transcript_path` exist HERE and not on SubagentStart, which is why they are captured on this side
# only. `.effort` measured as an OBJECT (`{"level":"xhigh"}`); the type switch below reads `.level` from an
# object and the value itself from a string, because a bare `.effort.level` against a string throws and jq
# would then emit NO record at all — one shape change would silently empty the ledger instead of one field.
#
# ORPHAN STOPS ARE REAL — measured, so no consumer should assume pairing. Driving one real Explore dispatch
# and then one manual `/compact` on the same session produced THREE ledger records, not two: the dispatch's
# matched start+stop, plus a third `stop` during the compaction with a fresh agent_id, an EMPTY agent_type,
# and an agent_transcript_path pointing at a file that was never written (the session's subagents/ dir held
# only the Explore transcript). So SubagentStop fires for something that emits no SubagentStart. Anything
# deriving wall duration must join and DISCARD unmatched stops rather than count records; anything reading
# agent_transcript_path must tolerate a dangling path. Not suppressed here — a hook records what the runtime
# hands it, and dropping the record would hide the very behaviour a future consumer needs to know about.
{
  _led="$PROJECT_DIR/.claude/claudehut/ledger"
  if mkdir -p "$_led" 2>/dev/null; then
    _line="$(jq -c --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{
      ts: $t,
      event: "stop",
      session_id: ((.session_id // "")[0:128]),
      agent_id:   ((.agent_id   // "")[0:128]),
      agent_type: ((.agent_type // "")[0:128]),
      effort:     ((if (.effort|type) == "object" then (.effort.level // "")
                    elif (.effort|type) == "string" then .effort
                    else "" end)[0:32]),
      agent_transcript_path: ((.agent_transcript_path // "")[0:512])
    }' <<<"$in" 2>/dev/null || true)"
    [ -n "$_line" ] && printf '%s\n' "$_line" >> "$_led/dispatches.jsonl" 2>/dev/null
  fi
} >/dev/null 2>&1 || true
# ------------------------------------------------------------------------------------------------------

# agent_type arrives PLUGIN-SCOPED for plugin-shipped subagents — "claudehut:claudehut-reuse-scanner", not the
# bare frontmatter name (https://code.claude.com/docs/en/hooks: "For subagents shipped by a plugin, this is the
# plugin-scoped identifier such as my-plugin:reviewer, not the bare frontmatter name"). Matching bare names
# alone meant every branch below fell through to *) and NONE of these four contracts ever fired in production.
# Strip the scope prefix so both forms match (a user-scope copy of an agent still arrives bare).
agent="$(jq -r '.agent_type // empty' <<<"$in" 2>/dev/null || true)"
# Strip ONLY this plugin's scope. `##*:` would strip the longest prefix, so "otherplugin:claudehut-planner"
# would fire claudehut's contract against another plugin's agent.
agent="${agent#claudehut:}"
DIR="$PROJECT_DIR/.claude/claudehut"

case "$agent" in
  claudehut-reuse-scanner)
    # canonical: tasks/<id>/reuse-scan.md ; legacy flat reuse-scan-*.md still accepted
    { ls "$DIR"/tasks/*/reuse-scan.md >/dev/null 2>&1 || ls "$DIR"/reuse-scan-*.md >/dev/null 2>&1; } \
      || block "claudehut-reuse-scanner returned without a reuse-scan artifact (.claude/claudehut/tasks/<NNNN-slug>/reuse-scan.md). Produce it before proceeding."
    ;;
  claudehut-planner)
    # canonical: tasks/<id>/plan.md ; legacy plans/*.md still accepted
    { ls "$DIR"/tasks/*/plan.md >/dev/null 2>&1 || ls "$DIR"/plans/*.md >/dev/null 2>&1; } \
      || block "claudehut-planner returned without a plan file (.claude/claudehut/tasks/<NNNN-slug>/plan.md). Produce it before proceeding."
    ;;
  claudehut-plan-reviewer)
    # WS-2 (issue 2): a DISPATCHED plan-reviewer must return a verdict artifact (tasks/<id>/plan-review.md),
    # so a spawned-but-empty review is blocked. Freshness proxy: newer than the state file. NB the state file
    # is rewritten by every claudehut-state call, so this means "since the last state mutation", NOT "since
    # SessionStart" — a tighter window than the original comment claimed, and it errs toward blocking a stale
    # verdict rather than accepting one. Fails open when state/session is absent or no
    # plan-review.md exists at all (never wedge — 06 §5). NB: this proves the agent PRODUCED a verdict when it
    # ran; the set-plan APPROVE gate is what makes the verdict mandatory before the write gate opens.
    sid_pr="$(jq -r '.session_id // empty' <<<"$in" 2>/dev/null || true)"
    STATE_FILE="$DIR/state/$sid_pr.json"
    if [ -n "$sid_pr" ] && [ -f "$STATE_FILE" ] && ls "$DIR"/tasks/*/plan-review.md >/dev/null 2>&1; then
      if ! find "$DIR"/tasks/*/plan-review.md -newer "$STATE_FILE" 2>/dev/null | grep -q .; then
        block "claudehut-plan-reviewer returned without a fresh verdict. Write the coverage table + APPROVE/REVISE to .claude/claudehut/tasks/<id>/plan-review.md before returning, then the main thread records claudehut-state set-plan-review."
      fi
    fi
    ;;
  claudehut-learner)
    # P1-1 FIX (defense-in-depth): the learner's contract is now to EXTRACT candidates — it writes
    # tasks/<id>/learn-candidates.jsonl, and capture-learnings runs merge-learnings.sh on that to write
    # learnings.jsonl (so the learner no longer touches learnings.jsonl directly). Verify the learner
    # produced a candidates file this session. Freshness proxy: newer than the state file — which every
    # claudehut-state call rewrites, so this actually means "since the last state mutation", not "since
    # SessionStart". Fails open when session_id or state file is absent, or no candidates file
    # exists at all (the inline small-tier path writes none) — never wedge on unexpected state (06 §5).
    sid_l="$(jq -r '.session_id // empty' <<<"$in" 2>/dev/null || true)"
    STATE_FILE="$DIR/state/$sid_l.json"
    if [ -n "$sid_l" ] && [ -f "$STATE_FILE" ] && ls "$DIR"/tasks/*/learn-candidates.jsonl >/dev/null 2>&1; then
      if ! find "$DIR"/tasks/*/learn-candidates.jsonl -newer "$STATE_FILE" 2>/dev/null | grep -q .; then
        block "claudehut-learner returned but no learn-candidates.jsonl was written this session. Extract at least one candidate to .claude/claudehut/tasks/<id>/learn-candidates.jsonl before returning."
      fi
    fi
    # If state file or candidates file absent: fail open (bootstrap may not have run, or first task)
    ;;
  *)
    : # text-returning agents (explorer, brainstormer, auditors) — no file contract to check
    ;;
esac
exit 0
