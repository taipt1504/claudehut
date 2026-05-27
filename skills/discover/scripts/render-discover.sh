#!/usr/bin/env bash
# render-discover.sh — pretty-print ClaudeHut status to stdout
set -euo pipefail

# shellcheck source=../../../scripts/hooks/lib/state.sh
source "${CLAUDE_PLUGIN_ROOT:-$(dirname "$(realpath "$0")")/../../..}/scripts/hooks/lib/state.sh"

PROJECT_ROOT="$(claudehut_project_root)"
[[ -d "$PROJECT_ROOT/.claudehut" ]] || { echo "ClaudeHut not initialized in $PROJECT_ROOT. Run /claudehut:init."; exit 0; }

TASK="$(claudehut_active_task)"
PHASE="$(claudehut_phase "$TASK")"

echo "ClaudeHut · v0.1.0"
echo
echo "ACTIVE TASK"
echo "  task_id: $TASK"
echo "  phase:   $PHASE"

if [[ "$TASK" != "none" ]]; then
  phase_file="$(claudehut_state_dir)/tasks/$TASK/phase.json"
  if [[ -f "$phase_file" ]]; then
    approvals="$(jq -r '.approvals | to_entries | map("\(.key) ✓") | join(", ")' "$phase_file" 2>/dev/null || echo "none")"
    retries="$(jq -r '.loop_retries // 0' "$phase_file")"
    echo "  approvals: $approvals"
    echo "  loop_retries: $retries/3"
  fi
fi

echo
echo "STACK"
stack="$PROJECT_ROOT/.claudehut/memory/stack-signals.json"
if [[ -f "$stack" ]]; then
  jq -r '
    "  build:     \(.build_tool // "?") · java \(.java_version // "?") · Spring Boot \(.spring_boot // "?")",
    "  web:       \(.web_stack // "?")",
    "  orm:       \(.orm | join(", ") // "?")",
    "  db:        \(.db | join(", ") // "?")",
    "  messaging: \(.messaging | join(", ") // "?")",
    "  cache:     \(.cache | join(", ") // "?")",
    "  mapper:    \(.mapper // "?") \(.mapstruct_version // "")",
    "  ser:       \(.serialization // "?") \(.jackson_version // "")"
  ' "$stack" 2>/dev/null
else
  echo "  (not detected — first SessionStart will populate)"
fi

echo
echo "INTEGRATIONS"
integ="$(claudehut_state_dir)/integrations.json"
if [[ -f "$integ" ]]; then
  ua="$(jq -r 'if .understand_anything.available then "✓" else "-" end' "$integ")"
  ua_path="$(jq -r '.understand_anything.graph_path // ""' "$integ")"
  gf="$(jq -r 'if .graphify.available then "✓" else "-" end' "$integ")"
  gf_path="$(jq -r '.graphify.graph_path // ""' "$integ")"
  gf_global="$(jq -r 'if .graphify.global_registry then "global=true" else "" end' "$integ")"
  echo "  understand_anything: $ua $ua_path"
  echo "  graphify:            $gf $gf_path $gf_global"
fi

echo
echo "PHASE SKILLS (6)"
echo "  brainstorm spec plan build verify-review learn"
echo
echo "META SKILLS"
echo "  discover init reuse-scan"
echo
echo "AGENTS (7 loaded in Sprint 1)"
echo "  claudehut-orchestrator (active)"
echo "  claudehut-brainstormer  claudehut-spec-writer  claudehut-planner"
echo "  claudehut-builder       claudehut-verifier     claudehut-learner"

echo
echo "HOOKS (8 events)"
echo "  SessionStart UserPromptSubmit PreToolUse PostToolUse"
echo "  SubagentStop Stop PreCompact FileChanged"

echo
echo "RECENT LEARNINGS (last 3)"
learnings="$PROJECT_ROOT/.claudehut/memory/learnings.jsonl"
if [[ -f "$learnings" && -s "$learnings" ]]; then
  tail -3 "$learnings" | jq -r '"  - [\(.category)] \(.title)"' 2>/dev/null
else
  echo "  (none yet)"
fi
