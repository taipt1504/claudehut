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
# WORKER_MODEL resolved below (5.3) — needs PLUGIN_ROOT + MAIN_REPO.

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
# 5.3: same three-tier worker-model resolution as run-parallel-group.sh.
WORKER_MODEL="$(bash "$SCRIPT_DIR/resolve-worker-model.sh" "$PLUGIN_ROOT" "$MAIN_REPO")"

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

# Max compile-fix attempts. The scaffold session is resumed (same context) with
# the compiler errors fed back each round — the documented headless retry pattern.
MAX_ATTEMPTS="${CLAUDEHUT_SCAFFOLD_MAX_ATTEMPTS:-3}"

# CLAUDEHUT_SCAFFOLD=1 bypasses the per-task surgical-scope + reuse-scan PreToolUse
# gates: the stub session writes the whole skeleton, including files no single task
# owns. The per-group gate (real enforcement) still runs later in run-parallel-group.
run_claude() {  # $1 = prompt ; $2 = optional resume args (e.g. "--resume <id>")
  local resume_args="${2:-}"
  CLAUDE_PROJECT_DIR="$MAIN_REPO" \
  CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
  CLAUDEHUT_TASK_ID="$TASK_ID" \
  CLAUDEHUT_WORKER=1 \
  CLAUDEHUT_SCAFFOLD=1 \
  claude --print --model "$WORKER_MODEL" --output-format json $resume_args "$1"
}

extract_session_id() { jq -r '.session_id // empty' 2>/dev/null; }

# Compile once; set COMPILE_OUT (combined output) and return the build's exit code.
# Single invocation per call — callers must NOT re-run the build for status.
COMPILE_OUT=""
do_compile() {
  [[ -z "$COMPILE" ]] && { COMPILE_OUT=""; return 0; }
  COMPILE_OUT="$( cd "$MAIN_REPO" && eval "$COMPILE" 2>&1 )"
}

# ── Attempt 1: generate ──────────────────────────────────────────────────────
resp="$(run_claude "$PROMPT" 2>>"$OUT_FILE")" || {
  echo "ERROR: stub scaffolding session failed — see $OUT_FILE" >&2
  printf '%s\n' "$resp" >> "$OUT_FILE"
  exit 1
}
printf '%s\n' "$resp" >> "$OUT_FILE"
session_id="$(printf '%s' "$resp" | extract_session_id)"
if [[ -z "$session_id" ]]; then
  echo "ERROR: could not capture scaffold session_id (--output-format json gave no .session_id)." >&2
  echo "       Response head:" >&2; printf '%s\n' "$resp" | head -5 >&2
  exit 1
fi

# ── Compile-fix loop ─────────────────────────────────────────────────────────
if [[ -z "$COMPILE" ]]; then
  echo "No build tool detected — skipping compile verification."
fi
attempt=1
while [[ -n "$COMPILE" ]]; do
  if do_compile; then
    echo "Stubs compile (attempt $attempt)."
    break
  fi
  errors="$COMPILE_OUT"
  if [[ "$attempt" -ge "$MAX_ATTEMPTS" ]]; then
    echo "ERROR: stubs still do not compile after $MAX_ATTEMPTS attempt(s). Parallel build cannot proceed." >&2
    echo "       Last errors (see $OUT_FILE):" >&2
    printf '%s\n' "$errors" | tail -20 >&2
    exit 1
  fi
  attempt=$((attempt+1))
  echo "Stubs failed to compile — retry $attempt/$MAX_ATTEMPTS (feeding errors back)..."
  fix_prompt="The stubs do not compile. Fix ONLY the compile errors below; keep signatures matching the contract. Re-run the compiler until green.

$errors"
  resp="$(run_claude "$fix_prompt" "--resume $session_id" 2>>"$OUT_FILE")" || {
    echo "ERROR: scaffold retry session failed — see $OUT_FILE" >&2
    exit 1
  }
  printf '%s\n' "$resp" >> "$OUT_FILE"
  new_id="$(printf '%s' "$resp" | extract_session_id)"
  [[ -n "$new_id" ]] && session_id="$new_id"
done

# Confirm a commit landed (worker may have skipped it).
if ! git -C "$MAIN_REPO" diff --quiet || ! git -C "$MAIN_REPO" diff --cached --quiet; then
  git -C "$MAIN_REPO" add -A
  git -C "$MAIN_REPO" commit -m "chore: scaffold stubs for ${TASK_ID}" >/dev/null 2>&1 || true
fi

echo "Stubs scaffolded + committed. Workers will branch from this commit."
