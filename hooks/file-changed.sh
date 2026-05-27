#!/usr/bin/env bash
# claudehut FileChanged hook — re-index memory when key files change externally.
#
# Schema note: FileChanged does NOT accept `hookSpecificOutput`. Use top-level
# `systemMessage` for an informational note to the user.
set -euo pipefail

input="$(cat)"
file="$(echo "$input" | jq -r '.file_path // ""')"

jq -n --arg f "$file" '{
  systemMessage: ("ClaudeHut: memory/rules updated externally — " + $f + ". Reload context if needed.")
}'
exit 0
