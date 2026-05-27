#!/usr/bin/env bash
# claudehut PostToolUse hook — format async after Java edits
set -euo pipefail

# shellcheck source=lib/state.sh
source "$(dirname "$0")/lib/state.sh"

input="$(cat)"
PROJECT_ROOT="$(claudehut_project_root)"
[[ -d "$PROJECT_ROOT/.claudehut" ]] || exit 0

file_path="$(echo "$input" | jq -r '.tool_input.file_path // ""')"
[[ -n "$file_path" ]] || exit 0

if [[ "$file_path" =~ \.java$ ]] && [[ -f "$PROJECT_ROOT/gradlew" ]]; then
  ( cd "$PROJECT_ROOT" && ./gradlew spotlessApply -PspotlessFiles="$file_path" >/dev/null 2>&1 || true ) &
fi

exit 0
