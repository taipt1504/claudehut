#!/usr/bin/env bash
# SubagentStart hook — OBSERVATION ONLY (v0.10).
#
# Records that a subagent was dispatched, and the agent_type the runtime actually delivered, to a
# session-scoped sidecar. It injects NO context and never blocks.
#
# Why observation before injection: the eventual design moves the round-invariant auditor payload (the rigor
# contract, enforcement set, pitfalls, vocabulary, suspects) out of the dispatch prompt and into this hook, so
# the main thread stops pasting it once per auditor per round. That switch is not safe to make blind. A
# SubagentStart hook is context-only with no error surface, so if it silently never fires, the auditors would
# lose the rigor contract entirely and reviews would degrade with every eval still green. Shipping the full
# payload here while the skill still instructs the model to paste it would instead pay for the same bytes
# twice. So v0.10 ships the cheap half: prove the hook fires, and capture the real agent_type. Doing that took
# one measured surprise already — scripts/verify-subagent.sh matched bare agent names for months while the
# runtime delivers the plugin-scoped form, and every eval passed because the fixtures fed the bare name.
#
# LEDGER: .claude/claudehut/ledger/dispatches.jsonl
# F5 (v0.12) moved it OUT of state/. It used to be state/<sid>.dispatches.jsonl, which claudehut-init
# gitignores AND bootstrap.sh:71-76 age-deletes after 7 days — so the one artifact every cost claim depends on
# was designed to evaporate (v0.12 plan §7.2: only 2 such files survive across all repos). It is now one
# shared append-only file, still gitignored (claudehut-init writes that rule SEPARATELY from the state/ one)
# and never swept. session_id is a FIELD now rather than the filename, since sessions share the file.
# MIGRATION: pre-v0.12 state/<sid>.dispatches.jsonl files are NOT migrated. They are session-ephemeral by
# their own contract and the ST-1 sweep already deletes them at 7 days; copying them forward would import
# records that predate agent_id and so can never be joined to a stop. They stay where they are and age out.
#
# FIELDS — measured against a real hook probe on Claude Code 2.1.234. The COMPLETE SubagentStart key set is:
# agent_id, agent_type, cwd, hook_event_name, prompt_id, session_id, transcript_path. Note what is NOT there:
# `effort` is ABSENT on SubagentStart (it is present on SubagentStop only). Writing an `effort` field here
# would produce exactly the hollow record v0.11 found 682 of in record-failure.sh — a key that matches
# nothing, indistinguishable from a real empty value. `agent_id` is the join key to the SubagentStop record
# scripts/verify-subagent.sh appends; that pair is what makes wall duration derivable.
set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
in="$(cat || true)"
command -v jq >/dev/null 2>&1 || exit 0

sid="$(jq -r '.session_id // empty' <<<"$in" 2>/dev/null || true)"
[ -n "$sid" ] || exit 0

# PROJECT_DIR, never the payload's .cwd — a worktree subagent runs under a different cwd, and rooting the path
# there would split that dispatch's start and its stop into two different ledgers, so the agent_id join would
# return nothing and the ledger would look merely empty rather than broken. .cwd is a recorded VALUE.
DIR="$PROJECT_DIR/.claude/claudehut/ledger"
mkdir -p "$DIR" 2>/dev/null || exit 0

# Every field capped inside jq, for the same reason the append is a single printf: the record must stay inside
# one buffered write so the concurrent dispatches of a fan-out cannot interleave. No lock, and none wanted on
# a hook that runs before every subagent.
line="$(jq -c --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{
  ts: $t,
  event: "start",
  session_id: ((.session_id // "")[0:128]),
  agent_id:   ((.agent_id   // "")[0:128]),
  agent_type: ((.agent_type // "")[0:128]),
  cwd:        ((.cwd        // "")[0:512])
}' <<<"$in" 2>/dev/null || true)"
[ -n "$line" ] && printf '%s\n' "$line" >> "$DIR/dispatches.jsonl" 2>/dev/null
exit 0
