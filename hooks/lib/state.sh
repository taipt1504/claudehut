#!/usr/bin/env bash
# claudehut state.sh — artifact-derived phase detection (Superpowers pattern).
#
# Principle: phase is DERIVED from artifacts present in the project + branch name.
# No JSON state file. No race conditions. Git branch = task identity.
#
# Phase derivation rules:
#   branch == main/master/trunk/develop  → phase = none (no active task)
#   no .claudehut/                       → phase = uninitialized
#   no design doc for branch             → phase = brainstorm
#   no contract doc for branch           → phase = spec
#   no plan doc for branch               → phase = plan
#   plan has unchecked tasks             → phase = build
#   findings.json exists, decision=fail  → phase = loop
#   findings.json decision=pass,         → phase = learn
#     no learnings entry for branch
#   learnings entry exists for branch    → phase = done

set -euo pipefail

claudehut_project_root() {
  echo "${CLAUDE_PROJECT_DIR:-$(pwd)}"
}

claudehut_claudehut_dir() {
  echo "$(claudehut_project_root)/.claudehut"
}

# Task id = git branch name, slashes → dashes for filesystem safety
# CLAUDEHUT_TASK_ID env var overrides derivation (used by worktree-launched builders).
claudehut_task_id() {
  if [[ -n "${CLAUDEHUT_TASK_ID:-}" ]]; then
    echo "$CLAUDEHUT_TASK_ID"
    return 0
  fi
  local root branch
  root="$(claudehut_project_root)"
  if ! git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
    echo "none"
    return 0
  fi
  branch="$(git -C "$root" symbolic-ref --short HEAD 2>/dev/null || echo "")"
  if [[ -z "$branch" ]]; then
    echo "none"
    return 0
  fi
  case "$branch" in
    main|master|trunk|develop|dev) echo "none"; return 0 ;;
  esac
  printf '%s' "$branch" | tr '/' '-' | tr -c '[:alnum:]-' '-'
}

claudehut_branch() {
  git -C "$(claudehut_project_root)" symbolic-ref --short HEAD 2>/dev/null || echo ""
}

claudehut_design_doc() {
  local task_id="${1:-$(claudehut_task_id)}"
  [[ "$task_id" == "none" ]] && { echo ""; return 0; }
  local file
  file="$(claudehut_claudehut_dir)/specs/${task_id}-design.md"
  [[ -f "$file" ]] && echo "$file" || echo ""
}

claudehut_contract_doc() {
  local task_id="${1:-$(claudehut_task_id)}"
  [[ "$task_id" == "none" ]] && { echo ""; return 0; }
  local file
  file="$(claudehut_claudehut_dir)/specs/${task_id}-contract.md"
  [[ -f "$file" ]] && echo "$file" || echo ""
}

claudehut_plan_doc() {
  local task_id="${1:-$(claudehut_task_id)}"
  [[ "$task_id" == "none" ]] && { echo ""; return 0; }
  local file
  file="$(claudehut_claudehut_dir)/plans/${task_id}-plan.md"
  [[ -f "$file" ]] && echo "$file" || echo ""
}

claudehut_findings_doc() {
  local task_id="${1:-$(claudehut_task_id)}"
  [[ "$task_id" == "none" ]] && { echo ""; return 0; }
  local file
  file="$(claudehut_claudehut_dir)/findings/${task_id}-findings.json"
  [[ -f "$file" ]] && echo "$file" || echo ""
}

# Plan has unchecked task = "- [ ]" line
claudehut_plan_has_unchecked() {
  local plan
  plan="$(claudehut_plan_doc "$@")"
  [[ -z "$plan" ]] && return 1
  grep -qE '^- \[ \]' "$plan"
}

claudehut_findings_decision() {
  local f
  f="$(claudehut_findings_doc "$@")"
  [[ -z "$f" ]] && { echo ""; return 0; }
  jq -r '.decision // ""' "$f" 2>/dev/null || echo ""
}

# Returns true if learnings.jsonl contains entry for this task_id
claudehut_has_learnings() {
  local task_id="${1:-$(claudehut_task_id)}"
  local f
  f="$(claudehut_claudehut_dir)/memory/learnings.jsonl"
  [[ -f "$f" ]] || return 1
  grep -qF "\"task_id\":\"$task_id\"" "$f"
}

# Main: derive phase from artifacts
claudehut_phase() {
  local task_id="${1:-$(claudehut_task_id)}"
  local cdir
  cdir="$(claudehut_claudehut_dir)"

  if [[ ! -d "$cdir" ]]; then echo "uninitialized"; return 0; fi
  if [[ "$task_id" == "none" ]]; then echo "none"; return 0; fi

  if [[ -z "$(claudehut_design_doc "$task_id")" ]]; then echo "brainstorm"; return 0; fi
  if [[ -z "$(claudehut_contract_doc "$task_id")" ]]; then echo "spec"; return 0; fi
  if [[ -z "$(claudehut_plan_doc "$task_id")" ]]; then echo "plan"; return 0; fi

  if claudehut_plan_has_unchecked "$task_id"; then echo "build"; return 0; fi

  local decision
  decision="$(claudehut_findings_decision "$task_id")"
  if [[ "$decision" == "fail" ]]; then echo "loop"; return 0; fi
  if [[ "$decision" == "pass" ]]; then
    if claudehut_has_learnings "$task_id"; then
      echo "done"
    else
      echo "learn"
    fi
    return 0
  fi

  # Plan complete but no findings.json yet → loop is next
  echo "loop"
}

# Reuse-scan freshness (still uses small JSON file per task — no race)
claudehut_reuse_scan_path() {
  local task_id="${1:-$(claudehut_task_id)}"
  echo "$(claudehut_claudehut_dir)/reuse-scans/${task_id}.json"
}

claudehut_reuse_scan_fresh() {
  local task_id="${1:-$(claudehut_task_id)}"
  local f
  f="$(claudehut_reuse_scan_path "$task_id")"
  [[ -f "$f" ]] || return 1
  local ts now_epoch ts_epoch
  ts="$(jq -r '.timestamp // "1970-01-01T00:00:00Z"' "$f" 2>/dev/null)"
  now_epoch="$(date +%s)"
  ts_epoch="$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null || \
              date -u -d "$ts" +%s 2>/dev/null || echo 0)"
  (( now_epoch - ts_epoch < 600 ))
}

# Stack signals (cached detection result; refresh weekly via stack-detector agent).
# Source-of-truth file is .claudehut/memory/stack-signals.md — markdown so it can
# be @imported from CLAUDE.md. Format: lines like `- key: value` (optionally with
# trailing `# comment`).
claudehut_stack_signal() {
  local key="$1"
  local f
  f="$(claudehut_claudehut_dir)/memory/stack-signals.md"
  [[ -f "$f" ]] || { echo ""; return 0; }
  # Note: grep returns non-zero when the key is absent. Without the `|| true`
  # guard, callers running under `set -e` (every hook) would abort silently
  # whenever stack-signals.md doesn't have a row for the requested key.
  local line
  line="$(grep -E "^- ${key}:" "$f" 2>/dev/null || true)"
  [[ -z "$line" ]] && { echo ""; return 0; }
  printf '%s' "$line" \
    | head -1 \
    | sed -E "s/^- ${key}:[[:space:]]*//; s/[[:space:]]*#.*//; s/[[:space:]]+$//"
}

claudehut_integration() {
  local backend="$1"
  local f
  f="$(claudehut_claudehut_dir)/memory/integrations.json"
  [[ -f "$f" ]] || { echo "false"; return 0; }
  case "$backend" in
    ua) jq -r '.understand_anything.available // false' "$f" 2>/dev/null ;;
    graphify) jq -r '.graphify.available // false' "$f" 2>/dev/null ;;
    *) echo "false" ;;
  esac
}

# Loop retry count = number of "refactor(loop)" commits on branch
claudehut_loop_retries() {
  local root branch
  root="$(claudehut_project_root)"
  branch="$(claudehut_branch)"
  [[ -z "$branch" ]] && { echo "0"; return 0; }
  git -C "$root" log --format='%s' "$branch" 2>/dev/null \
    | grep -cE '^refactor\(loop\)' \
    || echo "0"
}
