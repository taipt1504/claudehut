#!/usr/bin/env bash
# extract-nouns.sh — Extract candidate noun list from user prompt for reuse-scan
# Usage: extract-nouns.sh "Add an endpoint to fetch user purchase history"
# Output: space-separated noun candidates
set -euo pipefail

prompt="${*:-}"
[[ -z "$prompt" ]] && { echo ""; exit 0; }

STOPWORDS=" the a an of for to from with by in on at this that and or not is are was were be been being has have had do does did need needs needed want wants wanted should would could may might must can will shall add implement build design refactor fix create new make update modify change "

echo "$prompt" \
  | tr '[:upper:]' '[:lower:]' \
  | tr -c '[:alnum:][:space:]' ' ' \
  | tr -s ' ' '\n' \
  | awk -v sw="$STOPWORDS" '
    {
      if (length($0) < 3) next
      pad = " " $0 " "
      if (index(sw, pad)) next
      print $0
    }' \
  | sort -u \
  | tr '\n' ' '
echo
