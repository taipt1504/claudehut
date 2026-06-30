#!/usr/bin/env bash
# UserPromptSubmit hook. Re-anchors the current workflow phase and injects a small set of
# prompt-relevant learnings as additionalContext. Advisory only — never blocks. See 06 §3.
set -euo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
input="$(cat || true)"

command -v jq >/dev/null 2>&1 || { echo '{}'; exit 0; }

sid="$(jq -r '.session_id // empty' <<<"$input" 2>/dev/null || true)"
prompt="$(jq -r '.prompt // empty' <<<"$input" 2>/dev/null || true)"
STATE="$PROJECT_DIR/.claude/claudehut/state/$sid.json"

phase="$(jq -r '.phase // "discover"' "$STATE" 2>/dev/null || echo "discover")"
ctx="ClaudeHut — current phase: ${phase}. Follow the phase→skill map (claudehut:claudehut-workflow); do not skip the gated phases."

# Engaged-gap / cost (audit B.2): the workflow defaults complexity=full = all 7 phases.
# While still in the entry phase, reinforce Phase-0 triage so trivial/small tasks take the
# cheaper gate-verified fast lane instead of silently running full deliberation. Advisory only
# (never blocks); the write gate still verifies the chosen tier's bound deterministically.
if [ "$phase" = "discover" ]; then
  ctx="$ctx"$'\nPhase 0 — triage NOW if you have not: (a) SIZE — claudehut-state set-complexity <trivial|small|full> (trivial/small skip Brainstorm/Spec/Plan; the gate verifies the bound). (b) SHAPE — claudehut-state set-profile <feature|bugfix|audit|migration|investigation>: the shape decides the deliverable (audit/investigation → a findings.md, not code) and the mandatory auditors. set-phase implement BLOCKS until the profile is set.'
  # WS-1 off-path detector (advisory): task-shaped artifacts written OUTSIDE the canonical tasks/ store are
  # invisible to every gate (the 0011 failure: artifacts in .claude/prompt/). Warn at the entry phase only
  # (low noise); never blocks. Excludes the user's research area and the canonical store itself.
  offp="$(find "$PROJECT_DIR/.claude" \( -name reuse-scan.md -o -name brainstorm.md -o -name spec.md -o -name plan.md \) 2>/dev/null \
    | grep -vE '/\.claude/claudehut/tasks/|/\.claude/prompt/research/' | head -3 | sed "s#^${PROJECT_DIR}/##" | tr '\n' ' ' || true)"
  [ -n "$offp" ] && ctx="$ctx"$'\n⚠ Off-path task artifacts found (invisible to the gates/memory): '"$offp"$'— write workflow artifacts to .claude/claudehut/tasks/NNNN-<slug>/, not a bare path.'
fi

# Prompt-targeted learnings (P7 helper — optional; no-op until present)
if [ -x "$PLUGIN_ROOT/scripts/inject-learnings.sh" ] && [ -n "$prompt" ]; then
  rel="$("$PLUGIN_ROOT/scripts/inject-learnings.sh" --filter "$prompt" --top 5 2>/dev/null || true)"
  [ -n "$rel" ] && ctx="$ctx"$'\n\nRelevant learnings:\n'"$rel"
fi

jq -n --arg ctx "$ctx" '{hookSpecificOutput:{hookEventName:"UserPromptSubmit", additionalContext:$ctx}}'
