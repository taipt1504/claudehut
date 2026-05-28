#!/usr/bin/env bash
# run-parallel-group.sh <user-intent> <task-id> <plan-file> <group-num>
#
# Dispatches all unchecked tasks from <group-num> in <plan-file> in parallel:
# each task gets its own git worktree and a background `claude --print` process.
# After all complete, merges passing branches via merge-parallel-group.sh.
#
# Exits 0 if all tasks pass; exits 1 if any fail (prints failures to stderr).
set -euo pipefail

USER_INTENT="${1:-}"
TASK_ID="${2:-}"
PLAN_FILE="${3:-}"
GROUP_NUM="${4:-}"

[[ -n "$USER_INTENT" ]] || { echo "error: user-intent required" >&2; exit 1; }
[[ -n "$TASK_ID"     ]] || { echo "error: task-id required" >&2; exit 1; }
[[ -f "$PLAN_FILE"   ]] || { echo "error: plan file not found: $PLAN_FILE" >&2; exit 1; }
[[ -n "$GROUP_NUM"   ]] || { echo "error: group-num required" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
MAIN_REPO="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

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

# Find all unchecked tasks in this parallel group.
# Flushes each task block on the next "## Task" header or EOF.
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

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

declare -a PIDS=()

for TNUM in "${TASK_NUMS[@]}"; do
  BRANCH="claudehut/task-${TASK_ID}-${TNUM}"
  WT_PATH="${TMP_DIR}/wt-${TNUM}"
  OUT_FILE="${TMP_DIR}/out-${TNUM}.txt"
  PROMPT_FILE="${TMP_DIR}/prompt-${TNUM}.txt"

  # Create isolated worktree on a fresh branch
  if ! git -C "$MAIN_REPO" worktree add "$WT_PATH" -b "$BRANCH" HEAD 2>&1; then
    echo "ERROR: worktree add failed for task $TNUM" >&2
    echo 'worktree-fail' > "$OUT_FILE"
    PIDS+=(-1)
    continue
  fi

  # Generate dispatch prompt in main repo context (correct branch for state.sh)
  "$SCRIPT_DIR/dispatch-prompt.sh" "$USER_INTENT" "$TNUM" > "$PROMPT_FILE"

  # Launch builder; CLAUDEHUT_TASK_ID overrides branch-derived task id in worktree
  (
    cd "$WT_PATH"
    CLAUDE_PROJECT_DIR="$WT_PATH" \
    CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
    CLAUDEHUT_TASK_ID="$TASK_ID" \
    claude --print "$(cat "$PROMPT_FILE")" > "$OUT_FILE" 2>&1
  ) &
  PIDS+=($!)
done

# Wait for all background processes
for pid in "${PIDS[@]}"; do
  [[ "$pid" == "-1" ]] && continue
  wait "$pid" 2>/dev/null || true
done

echo "Group $GROUP_NUM: all processes finished. Collecting results..."

PASS_PAIRS=()
FAIL_TASKS=()
ERRORS=0

for TNUM in "${TASK_NUMS[@]}"; do
  OUT_FILE="${TMP_DIR}/out-${TNUM}.txt"
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
    echo "  Task $TNUM: FAIL (status=${STATUS:-missing-result-block})" >&2
    if [[ -f "$OUT_FILE" ]]; then
      echo "  --- last 20 lines of task $TNUM output ---" >&2
      tail -20 "$OUT_FILE" >&2
    fi
    FAIL_TASKS+=("$TNUM")
    ERRORS=$((ERRORS+1))
  fi
done

# Merge passing tasks back before surfacing failures
if [[ ${#PASS_PAIRS[@]} -gt 0 ]]; then
  "$SCRIPT_DIR/merge-parallel-group.sh" "$TASK_ID" "$PLAN_FILE" "${PASS_PAIRS[@]}"
fi

# Remove worktrees (best-effort)
for TNUM in "${TASK_NUMS[@]}"; do
  WT_PATH="${TMP_DIR}/wt-${TNUM}"
  [[ -d "$WT_PATH" ]] && git -C "$MAIN_REPO" worktree remove --force "$WT_PATH" 2>/dev/null || true
done

if [[ "$ERRORS" -gt 0 ]]; then
  echo "" >&2
  echo "Group $GROUP_NUM: ${#FAIL_TASKS[@]} task(s) failed: ${FAIL_TASKS[*]}" >&2
  echo "Resolve failures before proceeding to next group." >&2
  exit 1
fi

echo "Group $GROUP_NUM: all ${#TASK_NUMS[@]} task(s) passed."
