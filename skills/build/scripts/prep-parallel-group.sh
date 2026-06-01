#!/usr/bin/env bash
# prep-parallel-group.sh <user-intent> <task-id> <plan-file> <group-num>
# prep-parallel-group.sh --cleanup <manifest-file>
#
# NATIVE-TASK build dispatch (the default since v0.1.x): instead of forking headless
# `claude --print &` workers (the legacy run-parallel-group.sh pool), this script only
# PREPARES the parallel group — one git worktree + one ready-to-dispatch prompt per
# unchecked task — and emits a JSON MANIFEST. The orchestrator (main thread) then
# dispatches one native `Task(subagent_type="claudehut:claudehut-builder")` per manifest
# entry IN A SINGLE MESSAGE, so the workers run concurrently AND appear in the agent
# tracker (observable/controllable status — the whole point of the native-Task path).
#
# Each prompt is self-contained: it tells the builder its worktree path + that cwd does
# NOT persist across Bash calls, so it must operate via ABSOLUTE PATHS + `git -C` (proven
# by the mechanics spike). Worktrees persist after this script returns (the Task builders
# use them); `--cleanup <manifest>` tears them down after merge.
#
# NOTE: native Task workers run in-session, so there is NO per-worker pre-launch budget
# gate (that exists only on the legacy pool). Bound runaway workers with the per-task
# TASK_TIMEOUT mindset + the now-visible tracker. The legacy run-parallel-group.sh pool
# (with its budget gate) remains for budget-critical / headless runs.
set -euo pipefail

# Tear down every worktree recorded in a manifest (idempotent). Used by --cleanup
# AND by re-prep so a loop-retry / re-run of the same group does not leak the prior
# attempt's worktrees (the manifest path is fixed per group → would otherwise be
# overwritten with the new attempt, orphaning the old worktrees).
_cleanup_from_manifest() {
  local mf="$1" main wt tmp
  [[ -f "$mf" ]] || return 0
  main="$(jq -r '.main_repo // empty' "$mf" 2>/dev/null)"
  [[ -n "$main" ]] || return 0
  while IFS= read -r wt; do
    [[ -n "$wt" ]] && git -C "$main" worktree remove --force "$wt" 2>/dev/null || true
  done < <(jq -r '.tasks[].worktree' "$mf" 2>/dev/null)
  tmp="$(jq -r '.tmp_dir // empty' "$mf" 2>/dev/null)"
  [[ -n "$tmp" && -d "$tmp" ]] && rm -rf "$tmp"
  git -C "$main" worktree prune 2>/dev/null || true
}

# ---- cleanup mode -----------------------------------------------------------
if [[ "${1:-}" == "--cleanup" ]]; then
  MANIFEST="${2:?usage: prep-parallel-group.sh --cleanup <manifest-file>}"
  [[ -f "$MANIFEST" ]] || { echo "manifest not found: $MANIFEST" >&2; exit 1; }
  _cleanup_from_manifest "$MANIFEST"
  echo "cleaned up worktrees from $MANIFEST"
  exit 0
fi

# ---- prep mode --------------------------------------------------------------
USER_INTENT="${1:-}"
TASK_ID="${2:-}"
PLAN_FILE="${3:-}"
GROUP_NUM="${4:-}"
[[ -n "$USER_INTENT" ]] || { echo "error: user-intent required" >&2; exit 1; }
[[ -n "$TASK_ID"     ]] || { echo "error: task-id required" >&2; exit 1; }
[[ -f "$PLAN_FILE"   ]] || { echo "error: plan file not found: $PLAN_FILE" >&2; exit 1; }
[[ -n "$GROUP_NUM"   ]] || { echo "error: group-num required" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
MAIN_REPO="$(git -C "${CLAUDE_PROJECT_DIR:-$PWD}" rev-parse --show-toplevel)"

# Find all unchecked tasks in this parallel group (same awk as run-parallel-group.sh).
TASK_NUMS=()
while IFS= read -r n; do [[ -n "$n" ]] && TASK_NUMS+=("$n"); done < <(awk -v grp="$GROUP_NUM" '
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

LOG_DIR="$MAIN_REPO/.claudehut/logs"; mkdir -p "$LOG_DIR"
MANIFEST="$LOG_DIR/group${GROUP_NUM}-manifest.json"

# Idempotent re-prep: a loop-retry / re-run of this group reuses the fixed manifest
# path, so tear down any prior attempt's worktrees first (else they leak + a stale
# branch could be cherry-picked).
_cleanup_from_manifest "$MANIFEST"

if [[ ${#TASK_NUMS[@]} -eq 0 ]]; then
  jq -n --arg r "$MAIN_REPO" --argjson g "$GROUP_NUM" \
    '{main_repo:$r, group:$g, tmp_dir:"", tasks:[]}' | tee "$MANIFEST"
  echo "prep-parallel-group: no unchecked tasks in group $GROUP_NUM" >&2
  exit 0
fi

TMP_DIR="$(mktemp -d)"
tasks_json="[]"
for TNUM in "${TASK_NUMS[@]}"; do
  BRANCH="claudehut/task-${TASK_ID}-${TNUM}"
  WT_PATH="${TMP_DIR}/wt-${TNUM}"
  PROMPT_FILE="${TMP_DIR}/prompt-${TNUM}.txt"

  # Isolated worktree off HEAD (the stub commit). -B force-resets a stale branch.
  git -C "$MAIN_REPO" worktree add -B "$BRANCH" "$WT_PATH" HEAD >/dev/null 2>&1 \
    || { echo "ERROR: worktree add failed for task $TNUM" >&2; continue; }
  # Symlink .claudehut so in-worktree state/hooks resolve (untracked → not checked out).
  [[ -e "$WT_PATH/.claudehut" ]] || ln -s "$MAIN_REPO/.claudehut" "$WT_PATH/.claudehut"

  # Self-contained Task prompt: worktree header (absolute-path discipline) + the
  # per-task dispatch prompt. The orchestrator passes this VERBATIM as the Task prompt.
  {
    cat <<HDR
You are assigned git worktree: ${WT_PATH}  (branch: ${BRANCH}).
Your shell cwd does NOT persist across Bash calls — operate ENTIRELY via ABSOLUTE PATHS:
- Read / Edit / Write files only under ${WT_PATH}/… by absolute path.
- Run every git + build command as: git -C "${WT_PATH}" …   and   ( cd "${WT_PATH}" && ./gradlew … ).
- Make ONE commit of ONLY this task's files to branch ${BRANCH} (Conventional Commits; stage by
  explicit path — NEVER git add -A/. — do not tick plan checkboxes; the orchestrator merges + ticks).
- Do NOT touch the main checkout or any other worktree.
- End your output with the fenced claudehut-builder-result block (task_id, task, verify_status, commit_sha, error).

--- TASK DISPATCH ---
HDR
    CLAUDEHUT_TASK_ID="$TASK_ID" "$SCRIPT_DIR/dispatch-prompt.sh" "$USER_INTENT" "$TNUM"
  } > "$PROMPT_FILE"

  tasks_json="$(jq -c \
    --argjson n "$TNUM" --arg b "$BRANCH" --arg w "$WT_PATH" --arg p "$PROMPT_FILE" \
    '. + [{task_num:$n, branch:$b, worktree:$w, prompt_file:$p}]' <<<"$tasks_json")"
done

jq -n --arg r "$MAIN_REPO" --argjson g "$GROUP_NUM" --arg t "$TMP_DIR" --argjson tasks "$tasks_json" \
  '{main_repo:$r, group:$g, tmp_dir:$t, tasks:$tasks}' | tee "$MANIFEST"
echo "prep-parallel-group: prepared $(jq '.tasks|length' "$MANIFEST") worktree(s) for group $GROUP_NUM (manifest: $MANIFEST)" >&2
