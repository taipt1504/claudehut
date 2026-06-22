#!/usr/bin/env bash
# Skill-rail recorder for the SLASH-COMMAND path (audit P1-3).
#
# record-skill.sh closes the rail bypass for Claude calling the Skill TOOL (PreToolUse,
# matcher: Skill). But when a USER types `/claudehut:implement` directly, that path does
# NOT go through PreToolUse(Skill) — so the rail never opened and the gate stayed denied
# (fail-closed: safe but wedges slash-invokers). This recorder reflects record-skill.sh on
# the prompt/expansion path so a slash-invoked claudehut skill opens (implement) or closes
# (discover/brainstorm) the rail identically. NEVER blocks — recorder, not a gate.
#
# Payload-shape robust: extracts the skill name from `.tool_input.skill` if present, else
# from a leading `/claudehut:<skill>` (or `/<skill>`) slash command in `.prompt`. Works
# whether wired to a dedicated expansion event or to UserPromptSubmit.
set -euo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
in="$(cat || true)"

command -v jq >/dev/null 2>&1 || exit 0   # degrade: no recording without jq (rail stays closed)

sid="$(jq -r '.session_id // empty' <<<"$in" 2>/dev/null || true)"
[ -n "$sid" ] || exit 0

# 1) UserPromptExpansion carries the matched command name directly (the authoritative field);
#    also tolerate a Skill-tool payload (.tool_input.skill) so one script serves either wiring.
skill="$(jq -r '.command_name // .tool_input.skill // empty' <<<"$in" 2>/dev/null || true)"

# 2) else parse a leading slash command from the prompt: /claudehut:implement ...  →  claudehut:implement
if [ -z "$skill" ]; then
  prompt="$(jq -r '.expanded_prompt // .prompt // .user_prompt // empty' <<<"$in" 2>/dev/null || true)"
  tok="$(printf '%s' "$prompt" | sed -n 's@^[[:space:]]*/\([A-Za-z0-9:_-]\{1,\}\).*@\1@p' | head -1)"
  # only the claudehut namespace (or a bare phase-skill name) is relevant; mark-skill no-ops on the rest
  case "$tok" in
    claudehut:*|implement|discover|brainstorm) skill="$tok" ;;
  esac
fi

[ -n "$skill" ] || exit 0

CLAUDE_PROJECT_DIR="$PROJECT_DIR" "$PLUGIN_ROOT/bin/claudehut-state" \
  --session "$sid" mark-skill "$skill" >/dev/null 2>&1 || true
exit 0
