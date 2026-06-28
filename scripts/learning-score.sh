#!/usr/bin/env bash
# ClaudeHut learning scoreboard (v0.7, Issue 7). Reads the cross-session learnings store and prints
# MEASURED metrics so a user can answer "is the agent actually getting smarter?" — not vibes.
# Deterministic, read-only, never mutates the store. Fails open (exit 0, header only) when jq or the
# store is missing. Invoked by the /claudehut:claudehut-learning-report command, or run directly.
#
# HONESTY BOUNDARY (ponytail-gain rule): every number here is computed from learnings.jsonl. We do NOT
# invent an "X% smarter" score. The reward signal is EFFECTIVENESS — promoted pitfalls that recurred
# anyway (lower is better); a promotion that stops recurrence is a learning that stuck.
#
# Usage: learning-score.sh [--top N]   (default top 5)
set -uo pipefail

TOP=5
while [ $# -gt 0 ]; do case "$1" in --top) TOP="${2:-5}"; shift 2 ;; *) shift ;; esac; done

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
FILE="$PROJECT_DIR/.claude/claudehut/learnings.jsonl"

echo "  claudehut learning report                              measured from learnings.jsonl"
echo
command -v jq >/dev/null 2>&1 || { echo "  (jq not installed — cannot compute)"; exit 0; }
[ -f "$FILE" ] || { echo "  (no learnings store yet — run a task through the Learn phase first)"; exit 0; }

jq -R 'fromjson? // empty' "$FILE" 2>/dev/null | jq -s -r --argjson top "$TOP" '
  . as $all
  | ($all | length) as $n
  | if $n == 0 then "  (store is empty)" else
    ($all | map(.category // "note")) as $cats
    | ([ $all[] | select((.category // "") == "pitfall") ] | length) as $pf
    | ([ $all[] | select((.category // "") == "pitfall" and (.promoted // false)) ] | length) as $pfp
    | ([ $all[] | (.hits // 1) ] | add / $n) as $avghits
    | ([ $all[] | (.confidence // 0.5) ] | add / $n) as $avgconf
    | ([ $all[] | (.recurrence // 0) ] | add) as $recur
    | ([ $all[] | select(((.evidence // "") != "") and ((.evidence // "") != "no evidence")
                          and ((.evidence // "") | test(":[0-9]|\\.java|\\.sql|Test"))) ] | length) as $eviq
    | ([ $all[] | select(.applied != null) ] | length) as $apptracked
    | ([ $all[] | (.applied // 0) ] | add) as $appsum
    | (($eviq / $n * 100) | floor) as $evipct
    | (if $pf > 0 then (($pfp / $pf * 100) | floor) else 0 end) as $promorate
    | "  Store size       \($n) learnings"
      + "\n  By category      " + ( [ $cats | group_by(.)[] | "\(.[0]) \(length)" ] | join(" · ") )
      + "\n  Reinforcement    promoted \($pfp)/\($pf) pitfalls (\($promorate)%) · avg hits \(($avghits*10|floor)/10) · avg conf \(($avgconf*100|floor)/100)"
      + "\n  Quality          \($evipct)% carry real evidence (file:line / test)"
      + "\n  Effectiveness    promoted pitfalls recurred \($recur)× total  (lower = the rules are sticking)"
      + (if $apptracked > 0 then "\n  Application      \($appsum) applications tracked across \($apptracked) learnings" else "" end)
      + "\n\n  Top reinforced"
      + ( [ $all | sort_by(-((.hits // 1) * 1000 + (.confidence // 0)))[0:$top][]
            | "\n    \(.id // "L-?") [\(.category // "note")] \(.learning // "")  (hits \(.hits // 1), conf \((((.confidence // 0)*100)|floor)/100)\(if (.promoted // false) then ", PROMOTED" else "" end))" ] | join("") )
    end
' 2>/dev/null || echo "  (could not parse the store)"

echo
echo "  Per-repo deferred shortcuts → run /claudehut:capture-learnings; cuttable code → claudehut:review."
