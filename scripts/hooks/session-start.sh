#!/usr/bin/env bash
# claudehut SessionStart hook
# Artifact-derived phase: no state.json writes; phase computed each time from artifacts.
# Responsibilities:
#   1. Derive task_id from branch + phase from artifacts (state.sh)
#   2. Refresh stack-signals if missing
#   3. Detect reuse-backend integrations (UA, Graphify)
#   4. Inject context: task, phase, stack, recent learnings, next-step skill
set -euo pipefail

# shellcheck source=lib/state.sh
source "$(dirname "$0")/lib/state.sh"

PROJECT_ROOT="$(claudehut_project_root)"
CLAUDEHUT_DIR="$(claudehut_claudehut_dir)"
MEMORY_DIR="$CLAUDEHUT_DIR/memory"

if [[ ! -d "$CLAUDEHUT_DIR" ]]; then
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "SessionStart",
      additionalContext: "ClaudeHut available but project not initialized. Run /claudehut:init to scaffold .claudehut/ directory."
    }
  }'
  exit 0
fi

TASK_ID="$(claudehut_task_id)"
PHASE="$(claudehut_phase "$TASK_ID")"
BRANCH="$(claudehut_branch)"
RETRIES="$(claudehut_loop_retries)"

STACK_SUMMARY="not detected"
if [[ -f "$MEMORY_DIR/stack-signals.json" ]]; then
  ss="$MEMORY_DIR/stack-signals.json"
  w=$(jq -r '.web_stack // "?"' "$ss" 2>/dev/null)
  o=$(jq -r '.orm[0] // "?"' "$ss" 2>/dev/null)
  d=$(jq -r '.db[0] // "?"' "$ss" 2>/dev/null)
  m=$(jq -r '.messaging[0] // "?"' "$ss" 2>/dev/null)
  mp=$(jq -r '.mapper // "?"' "$ss" 2>/dev/null)
  sr=$(jq -r '.serialization // "?"' "$ss" 2>/dev/null)
  STACK_SUMMARY="web=$w orm=$o db=$d mq=$m mapper=$mp ser=$sr"
fi

ua_avail="false"; ua_path=""
[[ -f "$PROJECT_ROOT/.understand-anything/knowledge-graph.json" ]] && \
  { ua_avail="true"; ua_path=".understand-anything/knowledge-graph.json"; }

gf_avail="false"; gf_global="false"; gf_path=""
command -v graphify >/dev/null 2>&1 && {
  gf_avail="true"
  graphify global list >/dev/null 2>&1 && gf_global="true"
}
[[ -f "$PROJECT_ROOT/graphify-out/graph.json" ]] && gf_path="graphify-out/graph.json"

mkdir -p "$MEMORY_DIR"
jq -n \
  --arg ua "$ua_avail" --arg uap "$ua_path" \
  --arg gf "$gf_avail" --arg gfp "$gf_path" --arg gfg "$gf_global" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{
    understand_anything: {available: ($ua == "true"), graph_path: $uap},
    graphify: {available: ($gf == "true"), graph_path: $gfp, global_registry: ($gfg == "true")},
    detected_at: $ts
  }' > "$MEMORY_DIR/integrations.json"

RECENT="no learnings yet"
if [[ -f "$MEMORY_DIR/learnings.jsonl" ]]; then
  RECENT="$(tail -5 "$MEMORY_DIR/learnings.jsonl" 2>/dev/null | \
    jq -r '"- [\(.category)] \(.title)"' 2>/dev/null | head -5)"
fi

case "$PHASE" in
  none)          NEXT="No active task. Create a feature branch and workflow engages." ;;
  uninitialized) NEXT="Run /claudehut:init to set up the project." ;;
  brainstorm)    NEXT="MANDATORY next: /claudehut:brainstorm. Source-code edits BLOCKED until design doc exists." ;;
  spec)          NEXT="MANDATORY next: /claudehut:spec. Contract required before plan." ;;
  plan)          NEXT="MANDATORY next: /claudehut:plan. File-level tasks required before build." ;;
  build)         NEXT="Build phase. Use /claudehut:tdd-cycle per task. PreToolUse enforces surgical scope + reuse-scan." ;;
  loop)          NEXT="Verify/Review phase. Invoke /claudehut:verify-review. Retry counter: $RETRIES/3." ;;
  learn)         NEXT="All gates green. Invoke /claudehut:learn before finishing." ;;
  done)          NEXT="Task complete. Run claudehut-finish to archive, then merge or start next task." ;;
esac

CTX="ClaudeHut active
================
Task:     $TASK_ID  (branch: $BRANCH)
Phase:    $PHASE  (derived from artifacts)
Stack:    $STACK_SUMMARY
Backends: UA=$ua_avail, Graphify=$gf_avail (global=$gf_global)

Recent learnings:
$RECENT

Session-level rules: naming, package-layout, tdd-cycle, owasp-top10, secret-mgmt, coverage.

$NEXT

Run /claudehut:discover for full status."

jq -n --arg c "$CTX" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: $c
  }
}'
exit 0
