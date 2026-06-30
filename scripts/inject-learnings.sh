#!/usr/bin/env bash
# Helper (called by bootstrap.sh and inject-phase.sh). Reads learnings.jsonl, ranks entries by
# confidence x recency x hits, and emits the top-N as plain-text blocks. Recency is an exponential
# decay on `ts` with a ~30-day half-life (accepted default E5). Never errors out the caller.
#
# Usage: inject-learnings.sh [--top N] [--filter "keywords"]
#   --top N          how many to emit (default 12)
#   --filter STR     keep only learnings whose trigger/learning matches a word (>2 chars) in STR
set -euo pipefail

TOP=12; FILTER=""; SNAPSHOT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --top) TOP="${2:-12}"; shift 2 ;;
    --filter) FILTER="${2:-}"; shift 2 ;;
    --snapshot) SNAPSHOT="${2:-}"; shift 2 ;;   # WS-6: also write the injected entry IDs here (for .applied)
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
              * ( (-0.6931471805599453 * (if $age < 0 then 0 else $age end) / 30) | exp )
              # WS-6: a PROMOTED rule that keeps recurring did NOT stick — boost it so it re-surfaces loudly.
              * (if ((.promoted // false) and ((.recurrence // 0) > 0)) then 2.5 else 1 end) ) }
      )
    | ( if ($words | length) == 0 then .
        else map( select(
          ((.trigger // "") + " " + (.learning // "")) | ascii_downcase as $hay
          | ($words | any(. as $w | $hay | contains($w))) ) )
        end )
    # promoted entries live in their rule file now (always-on at edit-time) — injecting them too would
    # double-pay the tokens. EXCEPTION (WS-6): a promoted rule with recurrence>0 keeps being violated, so the
    # always-on rule is NOT working — re-inject it (boosted above) so the agent sees it again.
    | map(select((.promoted != true) or ((.recurrence // 0) > 0)))
    | sort_by(-._score)
    | .[0:$top]
    | .[]
    | "- [\(.category // "note")] \(.learning)  (\(.evidence // "no evidence")) [conf \(.confidence // 0), hits \(.hits // 1)\(if ((.promoted // false) and ((.recurrence // 0) > 0)) then ", RECURRING-PROMOTED" else "" end)]"
  ' 2>/dev/null || true

# WS-6: when asked, snapshot the IDs that were injected this session, so merge-learnings can stamp .applied
# on the ones that resurface. Same ranking/filter as above; emits a JSON array of ids.
if [ -n "$SNAPSHOT" ]; then
  jq -R 'fromjson? // empty' "$FILE" 2>/dev/null \
  | jq -s --argjson now "$now" --arg filter "$FILTER" --argjson top "$TOP" '
      ( ["the","and","for","fix","add","use","this","that","with","into","from","run","new","get","set","you","are","can","its","but"] ) as $stop
      | ( $filter | ascii_downcase | gsub("[^a-z0-9+ ]";" ") | split(" ")
          | map(. as $w | select(($w | length) > 2 and ($stop | index($w)) == null)) ) as $words
      | map(
          ( ($now - (((.ts // "1970-01-01T00:00:00Z") | fromdateiso8601?) // 0)) / 86400 ) as $age
          | . + { _score:
              ( (.confidence // 0.5) * (((.hits // 1) | if . < 1 then 1 else . end))
                * ( (-0.6931471805599453 * (if $age < 0 then 0 else $age end) / 30) | exp )
                * (if ((.promoted // false) and ((.recurrence // 0) > 0)) then 2.5 else 1 end) ) } )
      | ( if ($words | length) == 0 then .
          else map( select( ((.trigger // "") + " " + (.learning // "")) | ascii_downcase as $hay
            | ($words | any(. as $w | $hay | contains($w))) ) ) end )
      | map(select((.promoted != true) or ((.recurrence // 0) > 0)))
      | sort_by(-._score) | .[0:$top] | map(.id // empty)
    ' > "$SNAPSHOT" 2>/dev/null || true
fi
