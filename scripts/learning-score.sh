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
  [ .[] | select((.status // "") != "superseded") ] as $all
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

# W1 — surface the coverage-gap signal that was being written and read by nobody.
#
# merge-learnings.sh counts pitfalls that earned promotion but map to no rule file, and says why in its
# own comment: "An unmapped promotion is a coverage gap in the rule corpus, and the receipt is where it
# shows." It lands in the report JSON and in the per-session learn-receipt — and then nothing reads it.
# This scoreboard read only learnings.jsonl, where `unmapped` does not live (it is a receipt field, not a
# store field), and the /claudehut:claudehut-learning-report command renders this output verbatim. So the
# one signal telling you the rule corpus has a hole was computed every Learn pass and shown to no one.
#
# STRICTLY CONDITIONAL, for two reasons. A store with no receipt (the CI fixture) must print exactly what
# it printed before, and a clean run must not add a line that becomes wallpaper. The number still comes
# from a deterministic artifact, so the honesty boundary above holds: nothing here is computed by
# judgment.
RC_DIR="$PROJECT_DIR/.claude/claudehut/state"
if [ -d "$RC_DIR" ]; then
  RC_LATEST="$(ls -t "$RC_DIR"/*.learn-receipt.json 2>/dev/null | head -1 || true)"
  if [ -n "${RC_LATEST:-}" ] && [ -f "$RC_LATEST" ]; then
    UNMAPPED="$(jq -r '.unmapped // 0' "$RC_LATEST" 2>/dev/null || echo 0)"
    case "$UNMAPPED" in ''|*[!0-9]*) UNMAPPED=0 ;; esac
    [ "$UNMAPPED" -gt 0 ] && printf '  Rule coverage    %s promoted pitfall(s) map to no rule file — a gap in .claude/rules/ (from %s)\n' \
      "$UNMAPPED" "$(basename "$RC_LATEST")"
  fi
fi

echo
# W2 — the trailer used to read "Per-repo deferred shortcuts → … cuttable code → …", advertising two
# analyses this script does not perform: it reads one project's store and computes no per-repo breakdown,
# and nothing about cuttable code. On a surface whose stated contract is "every number here is computed
# from learnings.jsonl", a trailer that names findings it never derived is the same defect the numbers
# above are designed to avoid. Now it is a plain next-step pointer that claims nothing.
echo "  Next: /claudehut:capture-learnings to run a Learn pass · claudehut:review to re-audit the diff."
