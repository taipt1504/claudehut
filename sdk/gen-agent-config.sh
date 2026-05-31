#!/usr/bin/env bash
# sdk/gen-agent-config.sh — generate sdk/agent-config.json from agents/*.md.
#
# Phase 7.1 translation layer. The Claude Agent SDK ignores a SKILL's / agent's
# filesystem `allowed-tools`; subagents must be declared PROGRAMMATICALLY with an
# explicit `tools` (allowedTools) list (docs: agent-sdk/typescript — "programmatic
# `agents`/`allowedTools` always override filesystem settings"). This script is the
# single deterministic source of that mapping: each ClaudeHut persona ->
#   { description, tools (allowedTools), model, promptSource }
# plus the session-level orchestrator allowedTools + permissionMode. orchestrator.mjs
# consumes this; tests assert it (run-all.sh L26). Idempotent: re-run after editing
# any agents/*.md frontmatter.
#
# permissionMode rationale: builders/learner carry Edit/Write, run sandboxed in git
# worktrees under TDD gating, so the session runs `acceptEdits` (auto-accept edits).
# Read-only personas (reviewers, verifier, planner, ...) carry no Edit/Write in their
# `tools`, so acceptEdits cannot loosen them — least privilege is enforced per-agent
# by the tools array, not the session mode.
set -euo pipefail

_find_plugin_root() {
  if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" ]]; then echo "$CLAUDE_PLUGIN_ROOT"; return; fi
  local d; d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd -P)"
  while [[ "$d" != "/" && -n "$d" ]]; do
    [[ -f "$d/.claude-plugin/plugin.json" ]] && { echo "$d"; return; }
    d="$(dirname "$d")"
  done
  echo "error: cannot locate plugin root" >&2; exit 1
}
PLUGIN_ROOT="$(_find_plugin_root)"
OUT="$PLUGIN_ROOT/sdk/agent-config.json"

# frontmatter field reader (first --- block only)
_fm() { awk -v k="^$2:" '/^---[[:space:]]*$/{c++; next} c==1 && $0 ~ k {sub(/^[a-z_]+:[[:space:]]*/,""); print; exit}' "$1"; }

# Translate a CC `tools:` CSV into a JSON array. Task -> Agent (SDK renamed it; the
# orchestrator dispatches subagents via the "Agent" tool under the SDK).
_tools_json() {
  printf '%s' "$1" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | sed 's/^Task$/Agent/' | grep -v '^$' \
    | jq -R . | jq -cs .
}

agents_json="{}"
orch_tools='[]'
for f in "$PLUGIN_ROOT"/agents/*.md; do
  name="$(_fm "$f" name)"; [[ -n "$name" ]] || continue
  desc="$(_fm "$f" description)"
  tools_csv="$(_fm "$f" tools)"
  tools="$(_tools_json "$tools_csv")"
  rel="agents/$(basename "$f")"
  if [[ "$name" == "claudehut-orchestrator" ]]; then
    # The orchestrator is the SDK query driver, not an entry in agents{}. Its
    # allowedTools (incl. Agent) governs the top-level loop.
    orch_tools="$tools"
    continue
  fi
  # acceptEdits only matters at session level; per-agent we record whether the
  # persona is a writer (has Edit or Write) for the manifest + tests.
  writer=false
  printf '%s' "$tools_csv" | grep -qE '\b(Edit|Write)\b' && writer=true
  model="$(_fm "$f" model)"; [[ -n "$model" ]] || model="inherit"
  agents_json="$(jq -c \
    --arg n "$name" --arg d "$desc" --argjson t "$tools" \
    --arg m "$model" --arg p "$rel" --argjson w "$writer" \
    '. + {($n): {description:$d, tools:$t, model:$m, promptSource:$p, writer:$w}}' \
    <<<"$agents_json")"
done

jq -n \
  --argjson agents "$agents_json" \
  --argjson orch "$orch_tools" \
  '{
     "_generated_by": "sdk/gen-agent-config.sh from agents/*.md — do not hand-edit",
     "sessionPermissionMode": "acceptEdits",
     "orchestratorAllowedTools": $orch,
     "agents": $agents
   }' > "$OUT.tmp"

if [[ -f "$OUT" ]] && diff -q "$OUT.tmp" "$OUT" >/dev/null 2>&1; then
  rm -f "$OUT.tmp"; echo "agent-config: no change"
else
  mv "$OUT.tmp" "$OUT"; echo "agent-config: regenerated $OUT ($(jq '.agents|length' "$OUT") subagents)"
fi
