#!/usr/bin/env bash
# Money-gated LLM-judge tier (v0.7 benchmark P2). Verifies the ONE cognition claim the deterministic
# artifact-oracles can't: does the reuse-scanner REASON about contract/topology FIT, or surface-match on a
# keyword? (Requirement #1 "semantic judgment, not grep".) The artifact-oracle proves a Fit number is
# present + non-vacuous; this judge proves the REASONING behind it is real.
#
# Tiers of cost:
#   --self-test : FREE, deterministic — tests the verdict PARSER + threshold logic (no Claude). CI-safe.
#   (default)   : dry — prints what a live run would do, spends nothing.
#   --live      : COSTS TOKENS — runs the workflow on the held-out reuse-semantic-judgment fixture, then a
#                 judge model scores the produced reuse-scan.md against evals/judge/rubric-reuse-reasoning.md.
# Usage: evals/llm-judge.sh [--self-test | --live] [--model M] [--budget USD]
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
RUBRIC="$ROOT/evals/judge/rubric-reuse-reasoning.md"
FIXTURE="$ROOT/evals/tasks/reuse-semantic-judgment"
PASS_THRESHOLD=3   # judge scores 1-5; >=3 = genuine semantic reasoning
MODE=dry; MODEL=sonnet; BUDGET=4.00
while [ $# -gt 0 ]; do case "$1" in
  --self-test) MODE=selftest; shift ;;
  --live) MODE=live; shift ;;
  --model) MODEL="${2:-sonnet}"; shift 2 ;;
  --budget) BUDGET="${2:-4.00}"; shift 2 ;;
  *) shift ;;
esac; done

# parse_verdict: reads a judge JSON object on stdin, echoes "score=N verdict=...", returns 0 if score >=
# PASS_THRESHOLD else 1. Tolerates junk around the JSON (extracts the first {...} block). The whole tier's
# pass/fail logic lives HERE so it can be unit-tested without spending a cent.
parse_verdict() {
  command -v jq >/dev/null 2>&1 || { echo "score=? verdict=no-jq"; return 1; }
  local raw json score; raw="$(cat)"
  # extract the first {...} block that carries a "score" key (tolerates prose before/after, multi-line)
  json="$(printf '%s' "$raw" | tr '\n' ' ' | grep -oE '\{[^{}]*\}' 2>/dev/null | grep -m1 '"score"' || true)"
  score="$(printf '%s' "$json" | jq -r '.score // empty' 2>/dev/null)"
  case "$score" in ''|*[!0-9]*) echo "score=unpar;verdict=unparseable"; return 1 ;; esac
  if [ "$score" -ge "$PASS_THRESHOLD" ]; then echo "score=$score verdict=PASS (>=$PASS_THRESHOLD)"; return 0
  else echo "score=$score verdict=FAIL (<$PASS_THRESHOLD — surface-match, no contract reasoning)"; return 1; fi
}

if [ "$MODE" = selftest ]; then
  PASS=0; FAIL=0
  ok(){ PASS=$((PASS+1)); echo "  ok   - $1"; }
  bad(){ FAIL=$((FAIL+1)); echo "  FAIL - $1"; }
  echo "== llm-judge: verdict parser self-test (free) =="
  out="$(printf '%s' '{"score":4,"verdict":"good","reasons":"contract mismatch named"}' | parse_verdict)"; rc=$?
  { [ $rc -eq 0 ] && printf '%s' "$out" | grep -q 'score=4'; } && ok "score 4 → PASS" || bad "score 4 should PASS ($out rc=$rc)"
  out="$(printf '%s' '{"score":2,"verdict":"surface","reasons":"both are caches"}' | parse_verdict)"; rc=$?
  { [ $rc -eq 1 ] && printf '%s' "$out" | grep -q 'score=2'; } && ok "score 2 → FAIL" || bad "score 2 should FAIL ($out rc=$rc)"
  out="$(printf '%s' 'here is my verdict: {"score":5,"verdict":"x","reasons":"y"} thanks' | parse_verdict)"; rc=$?
  [ $rc -eq 0 ] && ok "tolerates prose around JSON (score 5 → PASS)" || bad "should extract JSON from prose ($out rc=$rc)"
  out="$(printf '%s' 'no json at all' | parse_verdict)"; rc=$?
  [ $rc -eq 1 ] && ok "unparseable → FAIL (fails safe)" || bad "unparseable should FAIL ($out rc=$rc)"
  out="$(printf '%s' '{"score":3,"verdict":"borderline","reasons":"some fit reasoning"}' | parse_verdict)"; rc=$?
  [ $rc -eq 0 ] && ok "threshold boundary (score 3 → PASS)" || bad "score 3 should PASS at threshold ($out rc=$rc)"
  echo; echo "LLM-JUDGE-SELFTEST: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; exit $?
fi

[ -f "$RUBRIC" ] || { echo "rubric missing: $RUBRIC" >&2; exit 2; }
[ -d "$FIXTURE/repo" ] || { echo "fixture missing: $FIXTURE/repo" >&2; exit 2; }

if [ "$MODE" = dry ]; then
  echo "(dry run — pass --live to spend tokens). Would: run the ClaudeHut workflow on $FIXTURE, then judge the"
  echo "produced reuse-scan.md with model=$MODEL (budget \$$BUDGET) against $RUBRIC; PASS if judge score >= $PASS_THRESHOLD."
  exit 0
fi

# ---- live ----
command -v claude >/dev/null || { echo "claude not on PATH" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq not on PATH" >&2; exit 2; }
SAN="$(mktemp -d)/plugin"; cp -R "$ROOT" "$SAN"; rm -rf "$SAN/evals" "$SAN/docs" "$SAN/.git"
work="$(mktemp -d)/work"; mkdir -p "$work"; cp -R "$FIXTURE/repo/." "$work/"
mkdir -p "$work/.claude"
printf '{"permissions":{"allow":["Write(.claude/claudehut/**)","Edit(.claude/claudehut/**)"]}}\n' > "$work/.claude/settings.json"
( cd "$work" && git init -q && git add -A && git commit -qm base >/dev/null 2>&1 )
prompt="$(cat "$FIXTURE/task.md")
This project uses the ClaudeHut plugin (7-phase workflow injected at session start). Drive it: triage the tier, run Discover (the reuse-scan is the artifact under test), write artifacts under .claude/claudehut/."
echo "[llm-judge] running workflow on reuse-semantic-judgment (model=$MODEL, budget \$$BUDGET)…"
( cd "$work" && CLAUDE_PROJECT_DIR="$work" CLAUDE_PLUGIN_ROOT="$SAN" claude --print --output-format json \
    --model "$MODEL" --max-budget-usd "$BUDGET" --dangerously-skip-permissions "$prompt" < /dev/null ) >/dev/null 2>&1 || true
scan="$(ls "$work"/.claude/claudehut/tasks/*/reuse-scan.md 2>/dev/null | head -1)"
[ -f "$scan" ] || { echo "[llm-judge] FAIL: no reuse-scan.md produced (workflow did not reach Discover)"; exit 1; }
echo "[llm-judge] judging $scan…"
jprompt="$(cat "$RUBRIC")

--- REUSE-SCAN UNDER TEST ---
$(cat "$scan")
--- END ---
Output STRICT JSON only: {\"score\": <1-5>, \"verdict\": \"...\", \"reasons\": \"...\"}."
verdict="$( claude --print --model "$MODEL" --max-budget-usd 1.00 "$jprompt" < /dev/null 2>/dev/null )"
echo "[llm-judge] judge said: $verdict"
res="$(printf '%s' "$verdict" | parse_verdict)"; rc=$?
echo "[llm-judge] $res"
exit $rc
