#!/usr/bin/env bash
# learn-extract.sh — propose candidate learning entries from git diff + plan/findings
# Output: JSONL to stdout; agent then categorizes + writes after secret-scan
set -euo pipefail

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
cd "$PROJECT_ROOT"

TASK_ID="${1:-}"
[[ -z "$TASK_ID" ]] && TASK_ID="$(cat "$PROJECT_ROOT/.claudehut/state/active-task.json" 2>/dev/null | jq -r '.task_id // ""')"
[[ -z "$TASK_ID" ]] && { echo "error: no task_id provided and no active task" >&2; exit 2; }

BASE_BRANCH="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|origin/||' || echo main)"

# Find merge base
MERGE_BASE="$(git merge-base HEAD "origin/$BASE_BRANCH" 2>/dev/null || echo HEAD~5)"

# Extract files touched
FILES=$(git diff --name-only "$MERGE_BASE"..HEAD || echo "")

# Compose candidate entries (heuristic — agent refines)
SESSION_ID="${CLAUDE_SESSION_ID:-unknown}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

for f in $FILES; do
  case "$f" in
    src/main/java/*Mapper.java)
      title="MapStruct mapper added: $(basename "$f" .java)"
      cat <<JSON
{"category":"pattern","title":"$title","files_touched":["$f"],"tags":["mapstruct","mapping"],"ts":"$TS","session_id":"$SESSION_ID","task_id":"$TASK_ID","hits":1}
JSON
      ;;
    src/main/java/*{Controller,Handler}.java)
      title="REST endpoint added in $(basename "$f" .java)"
      cat <<JSON
{"category":"pattern","title":"$title","files_touched":["$f"],"tags":["rest","spring-web"],"ts":"$TS","session_id":"$SESSION_ID","task_id":"$TASK_ID","hits":1}
JSON
      ;;
    src/main/resources/db/migration/V*.sql)
      title="Migration added: $(basename "$f" .sql)"
      cat <<JSON
{"category":"pattern","title":"$title","files_touched":["$f"],"tags":["migration","flyway"],"ts":"$TS","session_id":"$SESSION_ID","task_id":"$TASK_ID","hits":1}
JSON
      ;;
  esac
done
