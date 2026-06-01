#!/usr/bin/env bash
# prep-parallel-group-test.sh — PRODUCER proof for the native-Task build path.
# Runs prep-parallel-group.sh against a real temp git repo + plan fixture (NO model
# calls) and asserts it actually creates worktrees, emits a well-formed manifest with
# self-contained worktree prompts, and tears the worktrees down on --cleanup. Wired
# into tests/run-all.sh L16. Deterministic.
set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd -P)"
PREP="$PLUGIN_ROOT/skills/build/scripts/prep-parallel-group.sh"
PASS=0; FAIL=0; declare -a FL=()
ok(){ printf "  \033[32m✓\033[0m %s\n" "$1"; PASS=$((PASS+1)); }
no(){ printf "  \033[31m✗\033[0m %s :: %s\n" "$1" "$2"; FAIL=$((FAIL+1)); FL+=("$1: $2"); }

ROOT="$(mktemp -d)"; P="$ROOT/proj"; mkdir -p "$P"
(
  cd "$P"
  git init -q; git config user.email t@t; git config user.name t
  mkdir -p .claudehut/{plans,memory,logs,state}
  printf -- '- web: mvc\n' > .claudehut/memory/stack-signals.md
  git checkout -q -b feature/demo
  cat > .claudehut/plans/feature-demo-plan.md <<'PLAN'
## Task 1: Add Foo
**Parallel group:** 1
- Files: src/Foo.java
## Task 2: Add Bar
**Parallel group:** 1
- Files: src/Bar.java
## Task 3: Wire
**Parallel group:** 2
- Files: src/Wire.java
PLAN
  git add -A; git commit -qm base
)

MAN="$(CLAUDE_PROJECT_DIR="$P" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
  bash "$PREP" "Add Foo and Bar" feature-demo "$P/.claudehut/plans/feature-demo-plan.md" 1 2>/dev/null)"

# (1) manifest: group 1 has exactly its 2 tasks (not task 3 from group 2)
n="$(printf '%s' "$MAN" | jq '.tasks | length' 2>/dev/null)"
nums="$(printf '%s' "$MAN" | jq -c '[.tasks[].task_num]' 2>/dev/null)"
{ [[ "$n" == "2" ]] && [[ "$nums" == "[1,2]" ]]; } \
  && ok "prep manifest: group 1 → exactly tasks [1,2] (group-scoping correct)" \
  || no "prep manifest" "n=$n nums=$nums"

# (2) deterministic branches + a manifest file on disk
br="$(printf '%s' "$MAN" | jq -r '.tasks[0].branch')"
{ [[ "$br" == "claudehut/task-feature-demo-1" ]] && [[ -f "$P/.claudehut/logs/group1-manifest.json" ]]; } \
  && ok "prep: deterministic branch names + manifest persisted to .claudehut/logs" \
  || no "prep manifest" "branch=$br file=$(ls "$P/.claudehut/logs/" 2>/dev/null)"

# (3) worktrees actually exist on their branches
wt1="$(printf '%s' "$MAN" | jq -r '.tasks[0].worktree')"
{ [[ -d "$wt1" ]] && git -C "$P" worktree list | grep -q "claudehut/task-feature-demo-1"; } \
  && ok "prep: git worktree created on the task branch" \
  || no "prep worktree" "wt1=$wt1"

# (4) each prompt is self-contained: worktree header (absolute-path discipline) + task block
pf="$(printf '%s' "$MAN" | jq -r '.tasks[0].prompt_file')"
{ grep -q 'ABSOLUTE PATHS' "$pf" && grep -q 'git -C' "$pf" && grep -q 'claudehut-builder-result' "$pf"; } \
  && ok "prep: per-task prompt carries worktree + absolute-path + result-block instructions" \
  || no "prep prompt" "$(head -2 "$pf" 2>/dev/null)"

# (5) --cleanup removes the worktrees
bash "$PREP" --cleanup "$P/.claudehut/logs/group1-manifest.json" >/dev/null 2>&1
[[ "$(git -C "$P" worktree list | wc -l | tr -d ' ')" == "1" ]] \
  && ok "prep --cleanup: worktrees removed (only main checkout remains)" \
  || no "prep cleanup" "worktrees still present"

rm -rf "$ROOT"
echo ""
echo "prep-parallel-group: Pass=$PASS Fail=$FAIL"
[[ "$FAIL" -gt 0 ]] && { printf '  - %s\n' "${FL[@]}"; exit 1; } || exit 0
