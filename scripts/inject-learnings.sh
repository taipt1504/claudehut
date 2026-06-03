#!/usr/bin/env bash
# Helper (called by bootstrap.sh and inject-phase.sh). Reads learnings.jsonl, ranks entries by
# confidence x recency x hits, and emits the top-N as plain-text blocks. Recency is an exponential
# decay on `ts` with a ~30-day half-life (accepted default E5). Never errors out the caller.
#
# Usage: inject-learnings.sh [--top N] [--filter "keywords"]
#   --top N          how many to emit (default 12)
#   --filter STR     keep only learnings whose trigger/learning matches a word (>2 chars) in STR
set -euo pipefail

TOP=12; FILTER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --top) TOP="${2:-12}"; shift 2 ;;
    --filter) FILTER="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done

command -v jq >/dev/null 2>&1 || exit 0
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
FILE="$PROJECT_DIR/.claude/claudehut/learnings.jsonl"
[ -f "$FILE" ] || exit 0

now="$(date -u +%s)"

# Half-life 30 days: recency = 0.5 ^ (age_days / 30) = exp( ln(0.5) * age_days / 30 ).
jq -R 'fromjson? // empty' "$FILE" 2>/dev/null \
| jq -s -r --argjson now "$now" --arg filter "$FILTER" --argjson top "$TOP" '
    ( ["the","and","for","fix","add","use","this","that","with","into","from","run","new","get","set","you","are","can","its","but"] ) as $stop
    | ( $filter | ascii_downcase | gsub("[^a-z0-9+ ]";" ") | split(" ")
        | map(. as $w | select(($w | length) > 2 and ($stop | index($w)) == null)) ) as $words
    | map(
        ( ($now - (((.ts // "1970-01-01T00:00:00Z") | fromdateiso8601?) // 0)) / 86400 ) as $age
        | . + { _score:
            ( (.confidence // 0.5)
              * (((.hits // 1) | if . < 1 then 1 else . end))
              * ( (-0.6931471805599453 * (if $age < 0 then 0 else $age end) / 30) | exp ) ) }
      )
    | ( if ($words | length) == 0 then .
        else map( select(
          ((.trigger // "") + " " + (.learning // "")) | ascii_downcase as $hay
          | ($words | any(. as $w | $hay | contains($w))) ) )
        end )
    | sort_by(-._score)
    | .[0:$top]
    | .[]
    | "- [\(.category // "note")] \(.learning)  (\(.evidence // "no evidence")) [conf \(.confidence // 0), hits \(.hits // 1)]"
  ' 2>/dev/null || true
