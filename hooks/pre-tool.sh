#!/usr/bin/env bash
# claudehut PreToolUse hook — destructive-cmd block, phase gate (src/ in build),
# reuse-scan freshness, surgical-scope enforce. Rule injection now lives in
# Claude Code's native `.claude/rules/` loader (see hooks/pre-tool.sh tail).
set -euo pipefail

# shellcheck source=lib/state.sh
source "$(dirname "$0")/lib/state.sh"
PLUGIN_ROOT_PT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd -P)}"

input="$(cat)"

PROJECT_ROOT="$(claudehut_project_root)"
[[ -d "$PROJECT_ROOT/.claudehut" ]] || exit 0

# Canonicalize to the physical path. Workers run in git worktrees under temp dirs,
# and on macOS /tmp→/private/tmp and /var→/private/var are symlinks: the tool's
# file_path arrives canonicalized (/private/...) while CLAUDE_PROJECT_DIR may be
# the /tmp/... form. Without this, the relative-path strip below no-ops and every
# in-scope worker write is wrongly denied. (Found by the real Gradle e2e.)
PROJECT_ROOT="$(cd "$PROJECT_ROOT" 2>/dev/null && pwd -P || echo "$PROJECT_ROOT")"

tool_mode="edit"
for arg in "$@"; do
  case "$arg" in
    --tool) shift; tool_mode="${1:-edit}" ;;
  esac
done

# Bash mode: destructive command check
if [[ "$tool_mode" == "bash" ]]; then
  cmd="$(echo "$input" | jq -r '.tool_input.command // ""')"
  if echo "$cmd" | grep -qE '\brm -rf /|\bgit push.* --force\b|DROP DATABASE|\bkubectl delete\b|--no-verify\b'; then
    jq -n --arg c "$cmd" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: "ClaudeHut: destructive command blocked (best-effort speed-bump, NOT a sandbox — a determined command can evade this regex): \($c). If intentional, re-run via Claude Code permissions or rephrase."
      }
    }'
    exit 0
  fi
  exit 0
fi

# Edit/Write mode
file_path="$(echo "$input" | jq -r '.tool_input.file_path // ""')"
[[ -n "$file_path" ]] || exit 0

# Canonicalize the file path to physical form too (its dir exists even if the
# file is new), so the /tmp↔/private/tmp prefix match below is apples-to-apples.
_fp_dir="$(cd "$(dirname "$file_path")" 2>/dev/null && pwd -P || echo "$(dirname "$file_path")")"
file_path="$_fp_dir/$(basename "$file_path")"

# Always allow writes inside .claudehut/
case "$file_path" in
  "$PROJECT_ROOT/.claudehut/"*) exit 0 ;;
esac

# Migration safety gate (deterministic). A PreToolUse hook is a shell script and
# CANNOT dispatch an agent (sub-agents.md / hooks-guide.md), so write-time DB
# safety is a regex gate, not the orphan claudehut-migration-validator agent
# (that runs at Loop time for contextual checks). The file isn't written yet, so
# validate the tool_input.content via a temp file that keeps the real basename
# (the naming check needs it). Deny only on exit 1 (real issues); on exit 2
# (can't assess) allow — never block a write we cannot evaluate. Not bypassed for
# workers: it is deterministic with no hang risk.
case "$file_path" in
  */db/migration/V*.sql|*/db/migration/R*.sql)
    _mig_validator="$PLUGIN_ROOT_PT/skills/flyway-migration/scripts/validate-migration.sh"
    if [[ -x "$_mig_validator" ]]; then
      # Write tool carries .content; Edit carries .new_string (the text being
      # introduced); MultiEdit carries .edits[].new_string. Validate whatever new
      # SQL is being written so an Edit that introduces unsafe DDL is also caught
      # (the on-disk file is only the pre-edit state). Fall back to the on-disk
      # file only when no new text is available.
      _mig_content="$(echo "$input" | jq -r '
        .tool_input.content
        // .tool_input.new_string
        // ((.tool_input.edits // []) | map(.new_string) | join("\n"))
        // ""' 2>/dev/null)"
      _mig_target=""; _mig_tmp=""
      if [[ -n "$_mig_content" ]]; then
        _mig_tmp="$(mktemp -d)"; _mig_target="$_mig_tmp/$(basename "$file_path")"
        printf '%s' "$_mig_content" > "$_mig_target"
      elif [[ -f "$file_path" ]]; then
        _mig_target="$file_path"
      fi
      if [[ -n "$_mig_target" ]]; then
        # `if` exempts the capture from set -e (a failing validate-migration must
        # not abort the hook — we need its exit code to decide deny vs allow).
        if _mig_err="$(bash "$_mig_validator" "$_mig_target" 2>&1)"; then _mig_rc=0; else _mig_rc=$?; fi
        [[ -n "$_mig_tmp" ]] && rm -rf "$_mig_tmp"
        if [[ "$_mig_rc" -eq 1 ]]; then
          jq -n --arg f "$(basename "$file_path")" --arg e "$_mig_err" '{
            hookSpecificOutput: {
              hookEventName: "PreToolUse",
              permissionDecision: "deny",
              permissionDecisionReason: ("ClaudeHut migration gate: \($f) has online-safety issues:\n\($e)\nFix the migration or split into an expand-contract sequence, then retry.")
            }
          }'
          exit 0
        fi
      fi
    fi
    ;;
esac

# Stub-scaffold bypass: scaffold-stubs.sh runs a `claude -p` session at phase=build
# to write the WHOLE feature skeleton in one pass — including legitimate files no
# single task owns (shared enums, base types, package-info). Surgical scope +
# reuse-scan freshness are per-task gates that must NOT apply to scaffolding.
[[ -n "${CLAUDEHUT_SCAFFOLD:-}" ]] && exit 0

TASK_ID="$(claudehut_task_id)"
PHASE="$(claudehut_phase "$TASK_ID")"
PROFILE_PT="$(claudehut_route_profile "$TASK_ID")"

# Source-code edits are allowed only in the EDITABLE window:
#   - build (every profile), AND
#   - loop in the QUICK profile. Quick has no plan, so a verify-fail cannot
#     re-open a build phase via refactor-injection the way full does — its
#     post-route window (build+loop) is therefore ONE editable phase: the
#     orchestrator fixes findings inline and re-verifies. Full stays locked at
#     loop and re-enters build by injecting a refactor task into the plan.
_editable=""
[[ "$PHASE" == "build" ]] && _editable=1
[[ "$PROFILE_PT" == "quick" && "$PHASE" == "loop" ]] && _editable=1
if [[ -z "$_editable" ]]; then
  case "$file_path" in
    *.java|*.kt|*.kts|*.sql|src/*)
      jq -n --arg p "$PHASE" --arg f "$file_path" '{
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
          permissionDecision: "deny",
          permissionDecisionReason: "ClaudeHut: source-code edits not allowed in phase=\($p). File: \($f). Create the required .claudehut/ artifact for current phase first."
        }
      }'
      exit 0
      ;;
  esac
  exit 0
fi

# Build phase: reuse-scan freshness for new Java/Kotlin.
# Skipped for parallel workers (CLAUDEHUT_WORKER): a worker's RED step creates a
# NEW *Test.java (scaffold deliberately writes no tests), which would trip this
# freshness gate — and a headless `-p` worker cannot run /reuse-scan to satisfy it,
# so it would hang to the watchdog. The reuse decision was already made at plan
# time; re-gating it per-write is wrong for a worker. Scope-check below stays live.
# Also skipped for the QUICK route: reuse-scan is a brainstorm-phase gate, and
# quick deliberately skips brainstorm — there is no phase in which a quick task
# could run /reuse-scan, so gating new-file writes on it would deadlock the route.
if [[ -z "${CLAUDEHUT_WORKER:-}" ]] && [[ "$PROFILE_PT" != "quick" ]] && [[ "$file_path" =~ \.(java|kt|kts)$ ]] && [[ ! -f "$file_path" ]]; then
  if ! claudehut_reuse_scan_fresh "$TASK_ID"; then
    jq -n --arg f "$file_path" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: "ClaudeHut: creating new file \($f) requires fresh reuse-scan (< 10 min). Run /claudehut:reuse-scan <topic> first."
      }
    }'
    exit 0
  fi
fi

# Surgical scope: file must appear in current plan
PLAN="$(claudehut_plan_doc "$TASK_ID")"
if [[ -n "$PLAN" ]]; then
  rel="${file_path#$PROJECT_ROOT/}"
  if ! grep -qE "(create|modify|test):.*\b${rel//./\\.}\b" "$PLAN"; then
    jq -n --arg f "$rel" --arg p "$PLAN" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: "ClaudeHut: file \($f) not in current plan (\($p)). Edit plan to add file under correct task (or split into new task), commit plan edit, then retry. Don'\''t silently expand scope."
      }
    }'
    exit 0
  fi
fi

# Rule auto-load is handled natively: <project>/.claude/rules/*.md files
# (copied from the plugin by /claudehut:init) carry `paths:` frontmatter and
# are loaded by Claude Code's built-in loader when matching files are read.
exit 0
