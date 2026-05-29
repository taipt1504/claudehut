#!/usr/bin/env bash
# run-parallel-group.sh <user-intent> <task-id> <plan-file> <group-num>
#
# Dispatches all unchecked tasks from <group-num> in <plan-file> in parallel:
# each task gets its own git worktree and a background `claude --print` process.
# After all complete, merges passing branches via merge-parallel-group.sh, then
# runs a per-group compile+test gate.
#
# Worker sessions are FULL headless `claude` sessions (not Agent-tool subagents):
#   - persona/guardrails injected via --append-system-prompt (frontmatter is inert
#     for --print, so we cannot rely on the agent's model:/skills: fields)
#   - --model sonnet keeps per-task cost down
#   - .claudehut is symlinked into the worktree so the PreToolUse scope-check hook
#     and claudehut-state can read the plan (worktree only checks out committed
#     files; .claudehut is untracked)
#
# Exits 0 if all tasks pass AND the group gate passes; exits 1 otherwise.
set -euo pipefail

USER_INTENT="${1:-}"
TASK_ID="${2:-}"
PLAN_FILE="${3:-}"
GROUP_NUM="${4:-}"

[[ -n "$USER_INTENT" ]] || { echo "error: user-intent required" >&2; exit 1; }
[[ -n "$TASK_ID"     ]] || { echo "error: task-id required" >&2; exit 1; }
[[ -f "$PLAN_FILE"   ]] || { echo "error: plan file not found: $PLAN_FILE" >&2; exit 1; }
[[ -n "$GROUP_NUM"   ]] || { echo "error: group-num required" >&2; exit 1; }

# Per-task wall-clock budget (seconds). Watchdog kills a hung worker so a single
# stuck task cannot block the whole group indefinitely.
TASK_TIMEOUT="${CLAUDEHUT_TASK_TIMEOUT:-900}"
WORKER_MODEL="${CLAUDEHUT_WORKER_MODEL:-sonnet}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
# MAIN_REPO is the USER'S PROJECT repo (where worktrees/commits/gate happen) —
# NOT the plugin repo that hosts this script. Derive from the project dir.
MAIN_REPO="$(git -C "${CLAUDE_PROJECT_DIR:-$PWD}" rev-parse --show-toplevel)"

_find_plugin_root() {
  if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" ]]; then echo "$CLAUDE_PLUGIN_ROOT"; return; fi
  local d="$SCRIPT_DIR"
  while [[ "$d" != "/" && -n "$d" ]]; do
    [[ -f "$d/.claude-plugin/plugin.json" ]] && { echo "$d"; return; }
    d="$(dirname "$d")"
  done
  echo "error: plugin root not found" >&2; exit 1
}
PLUGIN_ROOT="$(_find_plugin_root)"

# Critical builder guardrails — injected into every worker via --append-system-prompt.
# These survive even when the claudehut plugin (and its agent frontmatter) is not
# resolvable by name. Keep in sync with agents/claudehut-builder.md Guardrails.
GUARDRAILS="$(cat <<'GUARD'
You are the ClaudeHut Builder executing EXACTLY ONE plan task in an isolated git worktree.
NON-NEGOTIABLE:
- Strict TDD: write ONE failing test, watch it fail for the RIGHT reason, write minimum
  production code, watch all tests pass, optionally refactor, then commit.
- The types/interfaces for this task already exist as compiling stubs on this branch. Your test
  asserts BEHAVIOR (the stub returns null / throws), so RED fails correctly; GREEN fills it in.
- SURGICAL SCOPE: edit ONLY files listed in this task Files list (create/modify/test). Never touch others.
- ONE commit, Conventional Commits format. Stage ONLY your task files by explicit path
  (git add <path>) — NEVER `git add -A`/`git add .` (that captures the .claudehut symlink
  and pollutes the merge). Do NOT tick plan checkboxes (orchestrator owns that).
- NEVER execute more than ONE task. Terminate after the single task commit.
- You MUST end your output with a fenced code block tagged claudehut-builder-result, containing
  task_id, task, verify_status (pass|fail), commit_sha, error. The orchestrator cannot merge without it.
GUARD
)"

# Find all unchecked tasks in this parallel group.
TASK_NUMS=()
while IFS= read -r n; do
  [[ -n "$n" ]] && TASK_NUMS+=("$n")
done < <(awk -v grp="$GROUP_NUM" '
  /^## Task [0-9]+:/ {
    if (cur > 0 && pg == grp+0 && done == 0) print cur
    line = $0; sub(/^## Task /, "", line); cur = line + 0
    pg = 0; done = 0; next
  }
  cur == 0 { next }
  /^- \[x\] complete/ { done = 1 }
  /^\*\*Parallel[[:space:]]group:\*\*/ {
    line = $0
    sub(/^\*\*Parallel[[:space:]]group:\*\*[[:space:]]*/, "", line)
    sub(/[^0-9].*$/, "", line)
    if (length(line) > 0) pg = line + 0
  }
  END { if (cur > 0 && pg == grp+0 && done == 0) print cur }
' "$PLAN_FILE")

if [[ ${#TASK_NUMS[@]} -eq 0 ]]; then
  echo "run-parallel-group: no unchecked tasks in group $GROUP_NUM — skipping"
  exit 0
fi

echo "Parallel group $GROUP_NUM: dispatching ${#TASK_NUMS[@]} task(s): ${TASK_NUMS[*]}"

# Load the real builder persona when the plugin agent is resolvable — this brings
# the full Goals/Gates/Guardrails + preloaded tdd-cycle skill (proper TDD steering),
# strictly better than the --append-system-prompt fragment. Falls back gracefully
# (e.g. plugin not installed in a dev/test env) to guardrails-only.
AGENT_REF="claudehut:claudehut-builder"
AGENT_ARGS=()
if claude agents list 2>/dev/null | grep -q "$AGENT_REF"; then
  AGENT_ARGS=(--agent "$AGENT_REF")
  echo "  workers load persona via --agent $AGENT_REF"
else
  echo "  --agent $AGENT_REF not resolvable — workers rely on --append-system-prompt guardrails"
fi

# Merge the project's committed settings so plugin enablement (and therefore the
# PreToolUse scope-check hook) is discovered even though each worker's cwd is an
# out-of-tree worktree. Best-effort: the real enforcement is the per-group gate.
SETTINGS_ARGS=()
[[ -f "$MAIN_REPO/.claude/settings.json" ]] && SETTINGS_ARGS=(--settings "$MAIN_REPO/.claude/settings.json")

TMP_DIR="$(mktemp -d)"
LOG_DIR="$MAIN_REPO/.claudehut/logs"
mkdir -p "$LOG_DIR"

# Cleanup runs on ANY exit (including early/error exits under set -e) so worktrees
# never leak. Remove each worktree via git (updates metadata), then drop TMP_DIR
# and prune stale refs.
cleanup() {
  local t
  for t in "${TASK_NUMS[@]}"; do
    [[ -d "${TMP_DIR}/wt-${t}" ]] && \
      git -C "$MAIN_REPO" worktree remove --force "${TMP_DIR}/wt-${t}" 2>/dev/null || true
  done
  rm -rf "$TMP_DIR"
  git -C "$MAIN_REPO" worktree prune 2>/dev/null || true
}
trap cleanup EXIT

PIDS=()
WATCHDOGS=()

for TNUM in "${TASK_NUMS[@]}"; do
  BRANCH="claudehut/task-${TASK_ID}-${TNUM}"
  WT_PATH="${TMP_DIR}/wt-${TNUM}"
  OUT_FILE="${LOG_DIR}/group${GROUP_NUM}-task${TNUM}.log"
  PROMPT_FILE="${TMP_DIR}/prompt-${TNUM}.txt"

  # Create isolated worktree on a fresh branch (branches from HEAD = stub commit).
  # -B (not -b) force-resets the branch to HEAD if it already exists, so a re-run
  # of a group after a failure does not collide with the prior attempt's branch.
  if ! git -C "$MAIN_REPO" worktree add -B "$BRANCH" "$WT_PATH" HEAD 2>&1; then
    echo "ERROR: worktree add failed for task $TNUM" >&2
    echo 'worktree-fail' > "$OUT_FILE"
    PIDS+=(-1); WATCHDOGS+=(-1)
    continue
  fi

  # Symlink .claudehut into the worktree so the scope-check hook + claudehut-state
  # can read the plan/state. Worktree only checks out committed files; .claudehut
  # is typically untracked, so without this the in-worktree hooks see
  # "uninitialized". Guard: if the project DOES track .claudehut it already exists
  # in the checkout — never nest a symlink inside it.
  [[ -e "$WT_PATH/.claudehut" ]] || ln -s "$MAIN_REPO/.claudehut" "$WT_PATH/.claudehut"

  # Generate dispatch prompt in main repo context (correct branch for state.sh)
  "$SCRIPT_DIR/dispatch-prompt.sh" "$USER_INTENT" "$TNUM" > "$PROMPT_FILE"

  # Launch worker (full headless session). CLAUDEHUT_TASK_ID overrides the
  # branch-derived task id so state lookups resolve the original task.
  # ${arr[@]+...} guards empty-array expansion under `set -u` on bash 3.2.
  (
    cd "$WT_PATH"
    CLAUDE_PROJECT_DIR="$WT_PATH" \
    CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
    CLAUDEHUT_TASK_ID="$TASK_ID" \
    CLAUDEHUT_WORKER=1 \
    claude --print \
           ${AGENT_ARGS[@]+"${AGENT_ARGS[@]}"} \
           --model "$WORKER_MODEL" \
           --append-system-prompt "$GUARDRAILS" \
           ${SETTINGS_ARGS[@]+"${SETTINGS_ARGS[@]}"} \
           "$(cat "$PROMPT_FILE")" > "$OUT_FILE" 2>&1
  ) &
  wpid=$!
  PIDS+=("$wpid")

  # Per-task watchdog: kill the worker if it exceeds TASK_TIMEOUT.
  ( sleep "$TASK_TIMEOUT"; kill -TERM "$wpid" 2>/dev/null ) &
  WATCHDOGS+=($!)
done

# Wait for all workers; cancel their watchdogs as they finish.
# kill + wait on the watchdog reaps it quietly (otherwise bash prints
# "Terminated: 15" job-control noise when the sleeper is signalled).
i=0
for pid in "${PIDS[@]}"; do
  if [[ "$pid" != "-1" ]]; then
    wait "$pid" 2>/dev/null || true
    wd="${WATCHDOGS[$i]}"
    if [[ "$wd" != "-1" ]]; then
      kill "$wd" 2>/dev/null || true
      wait "$wd" 2>/dev/null || true
    fi
  fi
  i=$((i+1))
done

echo "Group $GROUP_NUM: all processes finished. Collecting results... (logs: $LOG_DIR)"

PASS_PAIRS=()
FAIL_TASKS=()
ERRORS=0

for TNUM in "${TASK_NUMS[@]}"; do
  OUT_FILE="${LOG_DIR}/group${GROUP_NUM}-task${TNUM}.log"
  BRANCH="claudehut/task-${TASK_ID}-${TNUM}"

  STATUS=""
  if [[ -f "$OUT_FILE" ]]; then
    STATUS="$(awk '
      /^```claudehut-builder-result/{in_block=1; next}
      in_block && /^```/{in_block=0; next}
      in_block && /"verify_status"/{
        line=$0
        sub(/.*"verify_status"[[:space:]]*:[[:space:]]*"/, "", line)
        sub(/".*$/, "", line)
        if (line == "pass" || line == "fail") print line
      }
    ' "$OUT_FILE")"
  fi

  if [[ "$STATUS" == "pass" ]]; then
    PASS_PAIRS+=("${TNUM}:${BRANCH}")
    echo "  Task $TNUM: PASS"
  else
    echo "  Task $TNUM: FAIL (status=${STATUS:-missing-result-block}) — see $OUT_FILE" >&2
    FAIL_TASKS+=("$TNUM")
    ERRORS=$((ERRORS+1))
  fi
done

# Merge passing tasks back before surfacing failures or gating.
# Capture merge failure (|| MERGE_RC=) so set -e does not abort before the EXIT
# trap's worktree cleanup — and so a merge error is surfaced as our own exit 1.
MERGE_RC=0
if [[ ${#PASS_PAIRS[@]} -gt 0 ]]; then
  "$SCRIPT_DIR/merge-parallel-group.sh" "$TASK_ID" "$PLAN_FILE" "${PASS_PAIRS[@]}" || MERGE_RC=$?
fi
# (worktree cleanup happens in the EXIT trap — never leaks, even on early exit)

if [[ "$ERRORS" -gt 0 ]]; then
  echo "" >&2
  echo "Group $GROUP_NUM: ${#FAIL_TASKS[@]} task(s) failed: ${FAIL_TASKS[*]}" >&2
  echo "Resolve failures before proceeding to next group." >&2
  exit 1
fi
if [[ "$MERGE_RC" -ne 0 ]]; then
  echo "Group $GROUP_NUM: merge step failed (rc=$MERGE_RC). Resolve before next group." >&2
  exit 1
fi

# ── Per-group integration gate ───────────────────────────────────────────────
# Catch semantic merge breaks early (group N must compile + pass tests before
# group N+1 builds on it). Auto-detect build tool.
GATE=""
if [[ -x "$MAIN_REPO/gradlew" ]]; then
  GATE="./gradlew compileTestJava test"
elif [[ -f "$MAIN_REPO/pom.xml" ]]; then
  GATE="mvn -q test-compile test"
fi

if [[ -n "$GATE" ]]; then
  echo "Group $GROUP_NUM: running integration gate ($GATE)..."
  if ( cd "$MAIN_REPO" && eval "$GATE" ); then
    echo "Group $GROUP_NUM: gate PASSED."
  else
    echo "Group $GROUP_NUM: integration gate FAILED after merge." >&2
    echo "Merged code is on the working tree but does not compile/test." >&2
    echo "Resolve before proceeding to next group." >&2
    exit 1
  fi
else
  echo "Group $GROUP_NUM: no build tool detected (gradlew/pom.xml) — skipping gate."
fi

echo "Group $GROUP_NUM: all ${#TASK_NUMS[@]} task(s) passed + gate green."
