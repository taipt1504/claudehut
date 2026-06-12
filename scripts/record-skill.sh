#!/usr/bin/env bash
# PreToolUse hook (matcher: Skill) — the SKILL RECORDER (Issue-1 skill rail).
# Records which ClaudeHut skill the agent actually invoked, by calling
# `claudehut-state mark-skill <name>`. claudehut:implement sets implement_skill_ok=true
# (the proof gate-write.sh's skill rail requires before production code); discover/brainstorm
# reset it (new-task boundary). NEVER blocks, never emits a decision — it is a recorder,
# not a gate. Live-probed: PreToolUse fires for the Skill tool with payload
# {"tool_input":{"skill":"<name>"}}. See 06 §3 / 01 §4.
set -euo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
in="$(cat || true)"

command -v jq >/dev/null 2>&1 || exit 0   # degrade: no recording without jq (rail stays closed)

sid="$(jq -r '.session_id // empty' <<<"$in" 2>/dev/null || true)"
skill="$(jq -r '.tool_input.skill // empty' <<<"$in" 2>/dev/null || true)"
[ -n "$sid" ] && [ -n "$skill" ] || exit 0

CLAUDE_PROJECT_DIR="$PROJECT_DIR" "$PLUGIN_ROOT/bin/claudehut-state" \
  --session "$sid" mark-skill "$skill" >/dev/null 2>&1 || true
exit 0
