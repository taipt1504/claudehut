#!/usr/bin/env bash
# merge-parallel-group.sh <task-id> <plan-file> <task-num:branch> [<task-num:branch> ...]
#
# Called by the orchestrator after a parallel group of builder agents complete.
# For each task-num:branch pair:
#   1. Cherry-picks the branch's commits onto the current working tree (main branch).
#   2. Ticks the corresponding "- [ ] complete" checkbox in the plan file.
#
# Arguments:
#   $1 — task-id (e.g. "auth-service-login")
#   $2 — plan file path
#   $3+ — colon-separated "task_num:branch_name" pairs from claudehut-builder-result blocks
#
# Exits 0 on success; exits 1 with explanation on conflict or missing branch.
set -euo pipefail

TASK_ID="${1:-}"
PLAN_FILE="${2:-}"
shift 2 || true
PAIRS=("$@")

[[ -n "$TASK_ID" ]] || { echo "error: task-id required" >&2; exit 1; }
[[ -f "$PLAN_FILE" ]] || { echo "error: plan file not found: $PLAN_FILE" >&2; exit 1; }
[[ ${#PAIRS[@]} -gt 0 ]] || { echo "error: at least one task-num:branch required" >&2; exit 1; }

ERRORS=0

for pair in "${PAIRS[@]}"; do
  task_num="${pair%%:*}"
  branch="${pair#*:}"

  if [[ -z "$task_num" || -z "$branch" ]]; then
    echo "ERROR: malformed pair '$pair' (expected task_num:branch)" >&2
    ((ERRORS++)) || true
    continue
  fi

  # Verify branch exists
  if ! git rev-parse --verify "refs/heads/$branch" >/dev/null 2>&1 && \
     ! git rev-parse --verify "refs/worktrees/$branch" >/dev/null 2>&1; then
    echo "ERROR: branch '$branch' not found (task $task_num)" >&2
    ((ERRORS++)) || true
    continue
  fi

  # Find commits on the branch not in current HEAD (in chronological order)
  commits="$(git log --reverse --format='%H' HEAD.."$branch" 2>/dev/null || true)"
  if [[ -z "$commits" ]]; then
    echo "WARN: no new commits on branch '$branch' (task $task_num) — skipping cherry-pick"
  else
    echo "Merging Task $task_num from branch '$branch'..."
    while IFS= read -r sha; do
      if ! git cherry-pick --no-edit "$sha"; then
        echo "ERROR: cherry-pick conflict on $sha (task $task_num)" >&2
        echo "       Resolve conflict manually, then re-run phase." >&2
        git cherry-pick --abort 2>/dev/null || true
        ((ERRORS++)) || true
        break
      fi
    done <<< "$commits"
  fi

  if [[ $ERRORS -eq 0 ]]; then
    # Tick the checkbox for this task in the plan file
    # Matches "- [ ] complete" that appears after "## Task <N>:" block
    awk -v tnum="$task_num" '
      /^## Task [0-9]+:/{
        match($0, /^## Task ([0-9]+):/, arr)
        in_task = (arr[1] == tnum)
      }
      in_task && /^- \[ \] complete/{
        sub(/- \[ \]/, "- [x]")
        in_task = 0
      }
      {print}
    ' "$PLAN_FILE" > "${PLAN_FILE}.tmp" && mv "${PLAN_FILE}.tmp" "$PLAN_FILE"

    git add "$PLAN_FILE"
    git commit -m "chore(plan): task $task_num complete [parallel-merge]" --no-edit 2>/dev/null || \
      git commit -m "chore(plan): task $task_num complete [parallel-merge]" || true

    echo "  Task $task_num: merged + checkbox ticked."
  fi
done

if [[ $ERRORS -gt 0 ]]; then
  echo "$ERRORS merge error(s). Address conflicts before continuing Build phase." >&2
  exit 1
fi

echo "Parallel group merge complete."
