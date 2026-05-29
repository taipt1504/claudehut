#!/usr/bin/env bash
# scaffold-stubs.sh <user-intent> <task-id>
#
# Sequential pre-build step (runs ONCE before the parallel group loop).
# Generates compiling skeleton code for every type/interface/field the plan
# introduces, derived from the contract doc + plan Files lists, then commits it.
#
# WHY: parallel workers each branch from this stub commit, so the types and
# signatures they consume already exist and compile. This eliminates the three
# deadliest parallel-build failure modes at once:
#   - contract drift  (workers cannot invent divergent signatures)
#   - hidden dep       (a worker referencing another task's type finds it present)
#   - semantic merge   (shared ancestor types → cherry-pick can't merge-then-break)
#
# Stubs are signature-only: empty bodies that throw / return null / return default.
# Behavior is filled in per-task by the builders via TDD (test asserts behavior →
# fails against the stub → GREEN implements it).
#
# Exits 0 after a successful `compile` + commit; exits 1 if stubs don't compile.
set -euo pipefail

USER_INTENT="${1:-}"
TASK_ID="${2:-}"
WORKER_MODEL="${CLAUDEHUT_WORKER_MODEL:-sonnet}"

[[ -n "$USER_INTENT" ]] || { echo "error: user-intent required" >&2; exit 1; }
[[ -n "$TASK_ID"     ]] || { echo "error: task-id required" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
# MAIN_REPO is the USER'S PROJECT repo (compile/commit target) — NOT the plugin repo.
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
source "$PLUGIN_ROOT/hooks/lib/state.sh"

PROJECT_ROOT="$(claudehut_project_root)"
CONTRACT="$PROJECT_ROOT/.claudehut/specs/${TASK_ID}-contract.md"
PLAN="$PROJECT_ROOT/.claudehut/plans/${TASK_ID}-plan.md"

[[ -f "$CONTRACT" ]] || { echo "error: contract not found: $CONTRACT" >&2; exit 1; }
[[ -f "$PLAN"     ]] || { echo "error: plan not found: $PLAN" >&2; exit 1; }

# Build-tool compile command (compile only — no tests; stubs have no behavior).
COMPILE=""
if [[ -x "$MAIN_REPO/gradlew" ]]; then
  COMPILE="./gradlew compileJava compileTestJava"
elif [[ -f "$MAIN_REPO/pom.xml" ]]; then
  COMPILE="mvn -q test-compile"
fi

LOG_DIR="$PROJECT_ROOT/.claudehut/logs"
mkdir -p "$LOG_DIR"
OUT_FILE="$LOG_DIR/scaffold-stubs.log"

PROMPT="$(cat <<PROMPT_EOF
# ClaudeHut stub scaffolding — sequential pre-build step

Generate COMPILING SKELETON code for the feature below. This runs once before
parallel implementation; each builder will later fill in ONE stub's behavior via TDD.

## Rules
- Create every type, interface, field, method SIGNATURE that the contract defines
  and the plan's Files lists reference.
- Bodies are stubs ONLY: throw new UnsupportedOperationException("stub") for methods,
  return null/default for getters, leave fields declared but unassigned.
- DO NOT implement behavior. DO NOT write tests. Signatures must match the contract EXACTLY.
- The whole project MUST compile after your changes. Run \`$COMPILE\` and fix until green.
- Make ONE commit: \`chore: scaffold stubs for ${TASK_ID}\`.
- Do not tick any plan checkboxes.

## User intent
$USER_INTENT

## Contract (signatures are authoritative)
$(cat "$CONTRACT")

## Plan (Files lists name every file to scaffold)
$(cat "$PLAN")
PROMPT_EOF
)"

echo "Scaffolding stubs for ${TASK_ID}... (log: $OUT_FILE)"

CLAUDE_PROJECT_DIR="$MAIN_REPO" \
CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
CLAUDEHUT_TASK_ID="$TASK_ID" \
claude --print --model "$WORKER_MODEL" "$PROMPT" > "$OUT_FILE" 2>&1 || {
  echo "ERROR: stub scaffolding session failed — see $OUT_FILE" >&2
  exit 1
}

# Verify stubs compile (the worker should have, but gate it deterministically).
if [[ -n "$COMPILE" ]]; then
  echo "Verifying stubs compile ($COMPILE)..."
  if ! ( cd "$MAIN_REPO" && eval "$COMPILE" ); then
    echo "ERROR: stubs do not compile. Parallel build cannot proceed." >&2
    exit 1
  fi
fi

# Confirm a commit landed (worker may have skipped it).
if ! git -C "$MAIN_REPO" diff --quiet || ! git -C "$MAIN_REPO" diff --cached --quiet; then
  git -C "$MAIN_REPO" add -A
  git -C "$MAIN_REPO" commit -m "chore: scaffold stubs for ${TASK_ID}" >/dev/null 2>&1 || true
fi

echo "Stubs scaffolded + committed. Workers will branch from this commit."
