#!/usr/bin/env bash
# Skill-description trigger eval (IDEA-R2).
#
# Claude picks a skill from its `description:` alone. Every description edit is therefore a behavioural
# change with no test behind it — which is why rows 13 and 33 of the v0.11 plan, both of which rewrite
# descriptions, had no executable Verify-by until this existed.
#
# TWO MODES, and the split is the point:
#
#   --validate   DETERMINISTIC, free, runs in CI. Checks the fixture set is well-formed AND that each
#                fixture's recorded description still matches the live SKILL.md byte for byte. A
#                description edit therefore turns this RED until the fixture is refreshed and the model
#                arm re-run — the measurement cannot silently go stale.
#
#   (default)    MODEL arm. Asks a model, once per query, which skill it would invoke. Costs tokens and is
#                non-deterministic, so it belongs beside evals/llm-judge.sh and NOT in the deterministic
#                suite. Run it before and after a description change and compare.
#
# Usage: evals/trigger-eval.sh --validate
#        evals/trigger-eval.sh [--skill <name>] [--runs 3]
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$ROOT/evals/trigger-eval"
PASS=0; FAIL=0
ok(){  PASS=$((PASS+1)); echo "  ok   - $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  FAIL - $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq required"; exit 2; }

live_description() { # $1 skill name — the description exactly as the runtime sees it
  sed -n 's/^description: *//p' "$ROOT/skills/$1/SKILL.md" | head -1
}

# 95% Wilson score interval for k successes in n trials, printed beside every fraction the model arm
# reports. A bare "17/24" invites a decision the sample cannot support: two runs of the `review` fixture
# returned 17/24 then 18/24 and both were discarded as noise BY HAND, with no statistic behind the call.
# Their intervals — [0.508, 0.851] and [0.551, 0.880] — overlap almost entirely, so the discard is now
# mechanical rather than a judgement.
# Wilson and not the normal approximation, because recall measurements land on the boundaries: at 0/n and
# n/n the normal approximation collapses to a zero-width interval and can leave [0,1] altogether.
# Read the WIDTH as a trial budget: at n=24 the interval spans ~0.34, so nothing short of a ~30-point
# recall swing is distinguishable from noise, and detecting less needs more runs. Honest caveat — n here is
# queries × runs and the runs of one query are correlated, not iid, so the true interval is somewhat WIDER
# than what this prints. Treat it as a floor on the uncertainty, never a ceiling.
wilson() { # $1 successes  $2 trials -> "[lo, hi]"
  awk -v k="$1" -v n="$2" 'BEGIN{
    if (n <= 0) { printf "[n/a]"; exit }
    z = 1.96; z2 = z * z; p = k / n; d = 1 + z2 / n
    c = (p + z2 / (2 * n)) / d
    h = (z / d) * sqrt(p * (1 - p) / n + z2 / (4 * n * n))
    lo = c - h; hi = c + h
    if (lo < 0) lo = 0   # float noise only — Wilson is analytically inside [0,1], which is why it is used
    if (hi > 1) hi = 1
    printf "[%.3f, %.3f]", lo, hi
  }'
}

wilson_selftest() {
  # The arithmetic must be checkable WITHOUT the model arm — that arm costs tokens and is excluded from CI.
  # Hand-computed at z=1.96 and asserted as exact strings, not as membership in [0,1]: a range check would
  # not catch a normal-approximation regression, which is the one mistake this instrument exists to avoid
  # (it answers [0.000, 0.000] for 0/10 and [1.000, 1.000] for 10/10 and passes any range check).
  local k n want got
  while read -r k n want; do
    got="$(wilson "$k" "$n")"
    [ "$got" = "$want" ] \
      && ok "wilson $k/$n = $got" \
      || bad "wilson $k/$n = $got, expected $want"
  done <<'CASES'
0 10 [0.000, 0.278]
10 10 [0.722, 1.000]
17 24 [0.508, 0.851]
18 24 [0.551, 0.880]
CASES
  # The motivating case, asserted instead of argued: the two `review` runs are one measurement.
  local a_hi b_lo
  a_hi="$(wilson 17 24)"; a_hi="${a_hi##*, }"; a_hi="${a_hi%\]}"
  b_lo="$(wilson 18 24)"; b_lo="${b_lo#\[}";   b_lo="${b_lo%%,*}"
  awk -v x="$b_lo" -v y="$a_hi" 'BEGIN{ exit !(x + 0 < y + 0) }' \
    && ok "17/24 and 18/24 overlap ($b_lo < $a_hi) — noise, not a regression" \
    || bad "17/24 and 18/24 no longer overlap ($b_lo >= $a_hi) — a discard made by hand would now read as signal"
  # A fixture with an empty arm would otherwise divide by zero and print inf.
  got="$(wilson 0 0)"
  [ "$got" = "[n/a]" ] && ok "wilson on an empty sample reports n/a" || bad "wilson 0/0 = $got, expected [n/a]"
}

validate() {
  echo "== trigger-eval fixtures (deterministic) =="
  local n=0
  for f in "$DIR"/*.json; do
    [ -f "$f" ] || continue
    n=$((n+1))
    local name; name="$(basename "$f" .json)"
    jq -e . "$f" >/dev/null 2>&1 || { bad "$name: not valid JSON"; continue; }
    local np nn
    np="$(jq '.should_trigger | length' "$f")"; nn="$(jq '.should_not_trigger | length' "$f")"
    { [ "$np" -ge 8 ] && [ "$nn" -ge 8 ]; } \
      && ok "$name: $np positive / $nn negative queries" \
      || bad "$name: needs >=8 of each, has $np/$nn"
    # A query cannot be both a positive and a negative for the same skill.
    [ "$(jq '[.should_trigger[] as $q | .should_not_trigger[] | select(. == $q)] | length' "$f")" = "0" ] \
      && ok "$name: positive and negative sets are disjoint" \
      || bad "$name: a query appears in both sets"
    # THE assertion that gives this file teeth: a description edit invalidates the recorded measurement.
    local live rec; live="$(live_description "$name")"; rec="$(jq -r '.description' "$f")"
    if [ "$live" = "$rec" ]; then
      ok "$name: fixture description matches the live SKILL.md"
    else
      bad "$name: SKILL.md description changed since this fixture was recorded — refresh it and re-run the model arm"
    fi
  done
  [ "$n" -gt 0 ] || bad "no fixtures found under evals/trigger-eval/"
  # A positive for one skill should not be a positive for another; otherwise the set cannot discriminate.
  local dup
  dup="$(jq -rs '[.[] | .skill as $s | .should_trigger[] | {q:., s:$s}]
                 | group_by(.q) | map(select(length > 1)) | length' "$DIR"/*.json 2>/dev/null || echo 0)"
  [ "${dup:-0}" = "0" ] \
    && ok "every positive query maps to exactly one intended skill" \
    || bad "$dup quer(y/ies) are positives for more than one skill — the set cannot discriminate"
  echo "-- Wilson interval arithmetic (the statistic the model arm prints; no model call needed) --"
  wilson_selftest
  echo; echo "TRIGGER-EVAL(validate): $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
}

model_arm() {
  command -v claude >/dev/null 2>&1 || { echo "claude CLI required for the model arm"; exit 2; }
  local only="${1:-}" runs="${2:-3}"
  local names; names="$(jq -rs '[.[].skill] | join(", ")' "$DIR"/*.json)"
  echo "== trigger-eval model arm (COSTS TOKENS; not part of the deterministic suite) =="
  for f in "$DIR"/*.json; do
    local name; name="$(basename "$f" .json)"
    [ -z "$only" ] || [ "$only" = "$name" ] || continue
    local hit=0 tot=0 fp=0 ntot=0
    # Per-query lines, not just a ratio: "17/24" says the description under-triggers but not on WHAT, and
    # the whole point of this arm is to tell you which wording to change. Costs nothing extra — the calls
    # already happened.
    while IFS= read -r q; do
      local qhit=0 lost=""
      for _ in $(seq 1 "$runs"); do
        tot=$((tot+1))
        # </dev/null is load-bearing: `claude -p` reads stdin, and inside a `while read` loop it consumes
        # the loop's remaining queries. Without it exactly ONE query runs and the run reports 3/3 — a
        # perfect score measured on one eighth of the set.
        # --max-budget-usd is PER INVOCATION, and this loop floors at ~288 of them per full run (6 fixtures
        # × >=16 queries × 3 runs), so it caps a single runaway call, not the run total. Literal, like
        # llm-judge.sh:90's one-shot judge call, and deliberately loose for the shape: the answer is one
        # word, so a tighter cap would truncate a legitimate call to empty — which this loop records as a
        # MISS, silently corrupting the very recall number the eval exists to measure.
        ans="$(claude -p "Available skills: $names. For the request below, reply with ONLY the single skill name you would invoke, or the word none. Request: $q" --output-format text --max-budget-usd 1.00 </dev/null 2>/dev/null | tr -d '[:space:]')"
        if [ "$ans" = "$name" ]; then hit=$((hit+1)); qhit=$((qhit+1)); else lost="$lost ${ans:-empty}"; fi
      done
      # Record WHAT it answered instead. Hit/miss alone cannot be diagnosed: a first diagnostic run showed
      # every miss at 2/3 with no query failing consistently — run-to-run noise, not a wording defect — and
      # there was no way to tell whether the lost runs went to a sibling skill or to "none". Without the
      # competing answer, a description rewrite would be guessing.
      [ "$qhit" = "$runs" ] || printf '    miss  %s/%s  lost-to:%s  %s\n' "$qhit" "$runs" \
        "$(printf '%s' "$lost" | tr ' ' '\n' | grep -v '^$' | sort | uniq -c | sort -rn | awk '{printf "%s(%s)",$2,$1}' | head -c 60)" \
        "${q:0:56}"
    done < <(jq -r '.should_trigger[]' "$f")
    while IFS= read -r q; do
      local qfp=0
      for _ in $(seq 1 "$runs"); do
        ntot=$((ntot+1))
        ans="$(claude -p "Available skills: $names. For the request below, reply with ONLY the single skill name you would invoke, or the word none. Request: $q" --output-format text --max-budget-usd 1.00 </dev/null 2>/dev/null | tr -d '[:space:]')"
        [ "$ans" = "$name" ] && { fp=$((fp+1)); qfp=$((qfp+1)); }
      done
      [ "$qfp" = "0" ] || printf '    POACH %s/%s  %s\n' "$qfp" "$runs" "${q:0:72}"
    done < <(jq -r '.should_not_trigger[]' "$f")
    printf '  %-20s recall %s/%s %s   false-positives %s/%s %s\n' \
      "$name" "$hit" "$tot" "$(wilson "$hit" "$tot")" "$fp" "$ntot" "$(wilson "$fp" "$ntot")"
  done
}

case "${1:-}" in
  --validate) validate ;;
  --skill)    model_arm "${2:-}" "${4:-3}" ;;
  *)          model_arm "" "${2:-3}" ;;
esac
