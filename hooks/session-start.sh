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
      additionalContext: "ClaudeHut available but project not initialized. Run /claudehut:init to scaffold .claudehut/ directory.\n\nDispatch contract: once initialized, workflow phases run as Task() subagents (brainstorm→claudehut-brainstormer, spec→claudehut-spec-writer, plan→claudehut-planner, build→claudehut-builder, verify-review→claudehut-verifier, learn→claudehut-learner). Main thread = orchestrator."
    }
  }'
  exit 0
fi

TASK_ID="$(claudehut_task_id)"
PHASE="$(claudehut_phase "$TASK_ID")"
BRANCH="$(claudehut_branch)"
RETRIES="$(claudehut_loop_retries)"

# Active-task pointer (1.7): give the readers (learn-extract/run-archunit/owasp-scan)
# a real task pointer, and detect a branch rename that would orphan artifacts. The
# slug is derived from the branch; if a rename changes the slug, prior artifacts
# (specs/plans/findings under the old slug) become unreachable — warn loudly.
# Idempotent + atomic; claudehut-finish removes the pointer at task end.
STATE_DIR="$CLAUDEHUT_DIR/state"
PTR="$STATE_DIR/active-task.json"
TASK_WARN=""
if [[ "$PHASE" != "none" && "$PHASE" != "uninitialized" ]]; then
  if [[ -f "$PTR" ]]; then
    prev_task="$(jq -r '.task_id // ""' "$PTR" 2>/dev/null || echo "")"
    if [[ -n "$prev_task" && "$prev_task" != "$TASK_ID" ]] \
       && [[ -f "$CLAUDEHUT_DIR/specs/${prev_task}-design.md" ]] \
       && [[ ! -f "$CLAUDEHUT_DIR/specs/${TASK_ID}-design.md" ]]; then
      # A pointer cannot distinguish a branch RENAME (artifacts now orphaned)
      # from a normal SWITCH to a new task (artifacts safe on the old branch),
      # so state the fact neutrally and let the user decide — never accuse.
      TASK_WARN="Note: the previous active task was '$prev_task' (its artifacts live under that branch); you are now on '$TASK_ID', which has no artifacts yet. If '$TASK_ID' is a RENAME of '$prev_task', migrate specs/plans/findings to the new slug. If it is a separate task, ignore this."
    fi
  fi
  mkdir -p "$STATE_DIR"
  _ptr_tmp="$PTR.tmp.$$"
  jq -n --arg t "$TASK_ID" --arg b "$BRANCH" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{task_id: $t, branch: $b, slug: $t, updated_at: $ts}' > "$_ptr_tmp" && mv "$_ptr_tmp" "$PTR"
fi

STACK_SUMMARY="not detected"
if [[ -f "$MEMORY_DIR/stack-signals.md" ]]; then
  w=$(claudehut_stack_signal web)
  o=$(claudehut_stack_signal orm)
  d=$(claudehut_stack_signal db)
  m=$(claudehut_stack_signal messaging)
  mp=$(claudehut_stack_signal mapper)
  sr=$(claudehut_stack_signal serialization)
  STACK_SUMMARY="web=${w:-?} orm=${o:-?} db=${d:-?} mq=${m:-?} mapper=${mp:-?} ser=${sr:-?}"
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
# Atomic write (same-dir tmp + mv) so two concurrent SessionStart hooks for the
# same repo never leave a half-written / clobbered integrations.json. mv is only
# atomic within one filesystem, so the tmp MUST be in the same dir as the target.
_int_tmp="$MEMORY_DIR/integrations.json.tmp.$$"
jq -n \
  --arg ua "$ua_avail" --arg uap "$ua_path" \
  --arg gf "$gf_avail" --arg gfp "$gf_path" --arg gfg "$gf_global" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{
    understand_anything: {available: ($ua == "true"), graph_path: $uap},
    graphify: {available: ($gf == "true"), graph_path: $gfp, global_registry: ($gfg == "true")},
    detected_at: $ts
  }' > "$_int_tmp" && mv "$_int_tmp" "$MEMORY_DIR/integrations.json"

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

------------------------------------------------------------
ClaudeHut dispatch contract (non-negotiable)
------------------------------------------------------------
Main thread = ORCHESTRATOR. Your responsibilities:
  - own user dialog, context window, memory, advisor calls
  - track plan progress + phase transitions
  - dispatch each workflow phase as a SUBAGENT via the Task tool
  - review subagent output, surface concise status to user

Phase → subagent_type (set deliberately per phase model fit):
  brainstorm     → claudehut-brainstormer    (opus,   Socratic + reuse-scan)
  spec           → claudehut-spec-writer     (sonnet, contract drafting)
  plan           → claudehut-planner         (opus,   task decomposition)
  build          → claudehut-builder         (sonnet, TDD execution)
  verify-review  → claudehut-verifier        (sonnet, fans out 6 reviewers)
  learn          → claudehut-learner         (haiku,  memory consolidation)

When a workflow skill is invoked, the skill body instructs you to call
\`Task(subagent_type=..., prompt=<output of skill/scripts/dispatch-prompt.sh>)\`.
Do NOT execute phase steps inline in the main thread.

Context contract — per Anthropic Claude Code docs:
  - Subagent starts with a FRESH, ISOLATED context window.
  - Skills you loaded here in the main thread are NOT inherited.
  - Subagent receives: its frontmatter \`skills:\` preloads + CLAUDE.md
    hierarchy + git status + the prompt you pass via Task.
  - Pass anything the subagent needs explicitly in the Task prompt.
  - dispatch-prompt.sh composes that prompt deterministically (user
    intent + stack signals + conventions + recent learnings + prior
    artifacts).

Red flags (rationalizations to skip dispatch) — counter each:
  * \"task is small, I'll inline it\"       → wrong model + breaks gate
  * \"I already know the answer\"           → subagent's preloaded skill encodes the discipline; your in-context memory does not transfer to it anyway — dispatch and let it do the work right
  * \"subagent overhead is wasteful\"       → per-phase model is the point
  * \"I'll just write the code\"            → blocked by PreToolUse outside Build
Only exception: user explicitly says \`--inline\` or \"don't spawn a subagent\".

------------------------------------------------------------
$NEXT

Run /claudehut:discover for full status."

# Prepend the rename/orphan warning only when present (no blank-line drift otherwise).
[[ -n "$TASK_WARN" ]] && CTX="$TASK_WARN

$CTX"

jq -n --arg c "$CTX" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: $c
  }
}'
exit 0
