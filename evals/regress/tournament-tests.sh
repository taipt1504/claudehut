#!/usr/bin/env bash
# tournament-tests.sh — the T3 design tournament's deterministic part (M6c; appendix a2 §4.4). No model is called.
#   TN1      schedule: every unordered pair in both orders (3 options → 6), <2 options refused
#   TN2-TN3  a pair counts only when both orders agree; a judge that prefers whatever it reads first splits
#   TN4      a Condorcet winner over agreed pairs; a cycle → no-winner (exit 1)
#   TN5      a missing order → incomplete; repeats of one order that disagree split the pair (no re-asking until
#            the orders agree); repeats that agree are fine
#   TN6      ties agree with ties and give no win
#   TN7      malformed input (unknown id, bad winner, duplicate ids) → exit 2 with the reason
#   TN8      needs_user_confirmation is always true (T3: the user confirms the option)
# Prints "TOURNAMENT: N passed, M failed"; exit 1 on failure.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
command -v python3 >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || { echo "TOURNAMENT: 0 passed, 0 failed (no python3/jq)"; exit 0; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/tournament tests.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS+1)); echo "ok - $1"; else FAIL=$((FAIL+1)); echo "FAIL - $1"; fi; }
K="$ROOT/bin/claudehut-kernel"
j() { printf '{"first":"%s","second":"%s","winner":"%s"}' "$1" "$2" "$3"; }
doc() { local ids="$1"; shift; local js; js="$(IFS=,; echo "$*")"
  printf '{"options":[%s],"judgments":[%s]}\n' "$(for i in $ids; do printf '{"id":"%s"},' "$i"; done | sed 's/,$//')" "$js"; }
agg() { "$K" tournament aggregate "$1" --json 2>"$TMP/err"; }

s="$("$K" tournament schedule --options O0,O1,O2)"
"$K" tournament schedule --options O0 >/dev/null 2>&1; rc1=$?
check "TN1: 3 options → 6 ordered pairs, each pair in both orders; 1 option refused (rc=$rc1)" \
  'jq -e "length==6 and ([.[]|[.first,.second]|sort|join(\"-\")]|group_by(.)|map(length)|unique)==[2]" <<<"$s" >/dev/null && [ "$rc1" = 2 ]'

doc "A B" "$(j A B first)" "$(j B A second)" >"$TMP/agree.json"
out="$(agg "$TMP/agree.json")"; rc=$?
check "TN2: both orders pick A → agreed, winner A (rc=$rc)" 'jq -e ".status==\"winner\" and .winner==\"A\" and .pairs[0].state==\"agreed\"" <<<"$out" >/dev/null && [ "$rc" = 0 ]'
doc "A B" "$(j A B first)" "$(j B A first)" >"$TMP/bias.json"
out="$(agg "$TMP/bias.json")"; rc=$?
check "TN3: a first-position judge (A first → A, B first → B) splits the pair: no verdict, no winner (rc=$rc)" \
  'jq -e ".status==\"no-winner\" and .winner==null and .pairs[0].state==\"split\" and .consistency==0" <<<"$out" >/dev/null && [ "$rc" = 1 ]'

doc "A B C" "$(j A B first)" "$(j B A second)" "$(j A C first)" "$(j C A second)" "$(j B C first)" "$(j C B second)" >"$TMP/cw.json"
doc "A B C" "$(j A B first)" "$(j B A second)" "$(j B C first)" "$(j C B second)" "$(j C A first)" "$(j A C second)" >"$TMP/cyc.json"
o1="$(agg "$TMP/cw.json")"; o2="$(agg "$TMP/cyc.json")"; rc=$?
check "TN4: A beats B and C on agreed pairs → winner A; a cycle A>B>C>A → no-winner (rc=$rc)" \
  'jq -e ".winner==\"A\" and .wins.A==[\"B\",\"C\"]" <<<"$o1" >/dev/null && jq -e ".status==\"no-winner\" and .counts.agreed==3" <<<"$o2" >/dev/null && [ "$rc" = 1 ]'

doc "A B" "$(j A B first)" >"$TMP/miss.json"
doc "A B" "$(j A B second)" "$(j B A second)" "$(j A B first)" >"$TMP/redo.json"
doc "A B" "$(j A B first)" "$(j B A second)" "$(j A B first)" >"$TMP/same.json"
check "TN5: one order missing → incomplete; a re-asked order that changes its answer splits; one that repeats it agrees" \
  'jq -e ".status==\"incomplete\" and .pairs[0].state==\"missing\"" <<<"$(agg "$TMP/miss.json")" >/dev/null && jq -e ".pairs[0].state==\"split\" and .winner==null" <<<"$(agg "$TMP/redo.json")" >/dev/null && jq -e ".winner==\"A\"" <<<"$(agg "$TMP/same.json")" >/dev/null'

doc "A B" "$(j A B tie)" "$(j B A tie)" >"$TMP/tie.json"
check "TN6: tie in both orders → agreed tie, no win, no winner" \
  'jq -e ".pairs[0].state==\"agreed\" and .pairs[0].verdict==\"tie\" and .wins.A==[] and .status==\"no-winner\"" <<<"$(agg "$TMP/tie.json")" >/dev/null'

doc "A B" "$(j A Z first)" >"$TMP/bad1.json"; agg "$TMP/bad1.json" >/dev/null; r1=$?; g1="$(grep -c "two different option ids" "$TMP/err")"
doc "A B" "$(j A B best)" >"$TMP/bad2.json"; agg "$TMP/bad2.json" >/dev/null; r2=$?; g2="$(grep -c "first|second|tie" "$TMP/err")"
doc "A A" >"$TMP/bad3.json"; agg "$TMP/bad3.json" >/dev/null; r3=$?; g3="$(grep -c "unique string id" "$TMP/err")"
check "TN7: unknown id, bad winner, duplicate ids → exit 2 with the reason ($r1/$r2/$r3)" '[ "$r1$r2$r3" = 222 ] && [ "$g1$g2$g3" = 111 ]'

check "TN8: needs_user_confirmation is true for a clear winner too" 'jq -e ".needs_user_confirmation==true" <<<"$(agg "$TMP/cw.json")" >/dev/null'

echo "TOURNAMENT: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
