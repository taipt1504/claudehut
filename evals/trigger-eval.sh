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
    while IFS= read -r q; do
      for _ in $(seq 1 "$runs"); do
        tot=$((tot+1))
        ans="$(claude -p "Available skills: $names. For the request below, reply with ONLY the single skill name you would invoke, or the word none. Request: $q" --output-format text 2>/dev/null | tr -d '[:space:]')"
        [ "$ans" = "$name" ] && hit=$((hit+1))
      done
    done < <(jq -r '.should_trigger[]' "$f")
    while IFS= read -r q; do
      for _ in $(seq 1 "$runs"); do
        ntot=$((ntot+1))
        ans="$(claude -p "Available skills: $names. For the request below, reply with ONLY the single skill name you would invoke, or the word none. Request: $q" --output-format text 2>/dev/null | tr -d '[:space:]')"
        [ "$ans" = "$name" ] && fp=$((fp+1))
      done
    done < <(jq -r '.should_not_trigger[]' "$f")
    printf '  %-20s recall %s/%s   false-positives %s/%s\n' "$name" "$hit" "$tot" "$fp" "$ntot"
  done
}

case "${1:-}" in
  --validate) validate ;;
  --skill)    model_arm "${2:-}" "${4:-3}" ;;
  *)          model_arm "" "${2:-3}" ;;
esac
