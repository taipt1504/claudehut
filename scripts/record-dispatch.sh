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
# Sidecar: .claude/claudehut/state/<sid>.dispatches.jsonl  (ephemeral, gitignored with the rest of state/)
set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
in="$(cat || true)"
command -v jq >/dev/null 2>&1 || exit 0

sid="$(jq -r '.session_id // empty' <<<"$in" 2>/dev/null || true)"
agent="$(jq -r '.agent_type // empty' <<<"$in" 2>/dev/null || true)"
[ -n "$sid" ] || exit 0

DIR="$PROJECT_DIR/.claude/claudehut/state"
mkdir -p "$DIR" 2>/dev/null || exit 0

line="$(jq -nc --arg a "$agent" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{ts:$t, agent_type:$a}' 2>/dev/null || true)"
# Single short append: O_APPEND writes below PIPE_BUF are atomic, so concurrent dispatches cannot interleave
# a partial line. No lock needed, and none wanted on a hook that runs before every subagent.
[ -n "$line" ] && printf '%s\n' "$line" >> "$DIR/$sid.dispatches.jsonl" 2>/dev/null
exit 0
