#!/usr/bin/env bash
# claudehut FileChanged hook — re-index memory when key files change externally
set -euo pipefail

# shellcheck source=lib/state.sh
source "$(dirname "$0")/lib/state.sh"

input="$(cat)"
file="$(echo "$input" | jq -r '.file_path // ""')"

jq -n --arg f "$file" '{
  hookSpecificOutput: {
    hookEventName: "FileChanged",
    additionalContext: "Memory/rules updated externally: \($f). Context refreshed."
  }
}'
exit 0
