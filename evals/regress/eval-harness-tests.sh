#!/usr/bin/env bash
# eval-harness-tests.sh — the eval harness itself (EVL-1, docs/v0.20 08 §4, ADR K-13/K-17). No model calls.
#   R*  evals/run.sh: arm and auth validation in dry-run; the jq `// true` trap is gone; rows carry the new fields
#   Y*  evals/summarize.sh: aborted and pre-0.12.7 rows excluded, Δ per task × auth
#   P*  plugin-eval suites (evals/suites/**): every case has a prompt and ≥1 grader; graders have a known type
#   A*  plugin-eval.sh auth profile: api without a key and an unknown mode are refused before any run
# Prints "EVAL-HARNESS-TESTS: N passed, M failed"; exit 1 on failure.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/eval-harness.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "ok - $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL - $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
RUN="$ROOT/evals/run.sh"; SUM="$ROOT/evals/summarize.sh"

# ── R: run.sh ──────────────────────────────────────────────────────────────────────────────────────────────
out="$(env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN bash "$RUN" reuse-exists)"
check "R1: dry run, auto auth without a key resolves to plan" 'grep -q "auth=plan" <<<"$out"'
out="$(ANTHROPIC_API_KEY=x bash "$RUN" reuse-exists)"
check "R2: auto auth with a key resolves to api" 'grep -q "auth=api" <<<"$out"'
env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN bash "$RUN" --auth api reuse-exists >/dev/null 2>&1; rc=$?
check "R3: --auth api without a key is refused (bare never reads the subscription login)" '[ "$rc" = 2 ]'
bash "$RUN" --mode nope reuse-exists >/dev/null 2>&1; rc=$?
check "R4: an unknown arm is a usage error" '[ "$rc" = 2 ]'
out="$(bash "$RUN" --mode both reuse-exists)"
check "R5: --mode both is accepted" 'grep -q "mode=both" <<<"$out"'
check "R6: the jq trap that made every is_error true is gone" '! grep -v "^[[:space:]]*#" "$RUN" | grep -q "is_error // true"'
check "R7: rows carry auth_mode, claude_version, aborted, budget_usd" 'grep -q "auth_mode:\$auth" "$RUN" && grep -q "claude_version:\$cver" "$RUN" && grep -q "aborted:\$aborted" "$RUN" && grep -q "budget_usd:\$budget" "$RUN"'
check "R8: a budget-killed run is not scored" 'grep -q "error_max_budget_usd" "$RUN" && grep -q "oracle=null" "$RUN"'

# ── Y: summarize.sh ────────────────────────────────────────────────────────────────────────────────────────
mkdir -p "$TMP/res"
printf '%s\n' '{"task":"t1","mode":"claudehut","auth_mode":"plan","aborted":false,"pass_at_1":1,"ts":"2026-10-21T00:00:00Z"}' \
  '{"task":"t1","mode":"claudehut","auth_mode":"plan","aborted":true,"pass_at_1":null,"ts":"2026-10-21T00:00:00Z"}' \
  '{"task":"t1","mode":"claudehut","auth_mode":"plan","aborted":false,"pass_at_1":0,"ts":"2026-10-21T00:00:00Z"}' \
  '{"task":"t1","mode":"claudehut","pass_at_1":1,"ts":"2026-06-21T00:00:00Z"}' \
  '{"task":"t1","mode":"claudehut","auth_mode":"api","aborted":false,"pass_at_1":1,"ts":"2026-10-21T00:00:00Z"}' >"$TMP/res/claudehut.jsonl"
printf '%s\n' '{"task":"t1","mode":"baseline","auth_mode":"plan","aborted":false,"pass_at_1":0,"ts":"2026-10-21T00:00:00Z"}' >"$TMP/res/baseline.jsonl"
j="$(CLAUDEHUT_EVAL_RESULTS="$TMP/res" bash "$SUM" --json)"
check "Y1: aborted and pre-0.12.7 rows are excluded (2 scored plan runs)" '[ "$(jq -r ".[]|select(.auth==\"plan\")|.runs_with" <<<"$j")" = 2 ]'
check "Y2: Δ = with − without (0.5)" '[ "$(jq -r ".[]|select(.auth==\"plan\")|.delta" <<<"$j")" = 0.5 ]'
check "Y3: auth modes are never mixed in one row" '[ "$(jq "length" <<<"$j")" = 2 ]'

# ── P: plugin-eval suites ──────────────────────────────────────────────────────────────────────────────────
SU="$ROOT/evals/suites"
if [ -d "$SU" ]; then
  ncase=0; nbad=0
  while IFS= read -r c; do
    d="$(dirname "$c")"; ncase=$((ncase+1))
    ng="$(ls "$d"/graders/*.md 2>/dev/null | wc -l | tr -d ' ')"
    [ "$ng" -ge 1 ] || { nbad=$((nbad+1)); echo "   no grader: $d"; continue; }
    for g in "$d"/graders/*.md; do
      t="$(sed -n '2,8s/^type: *//p' "$g" | head -1)"
      case "$t" in regex|tool_used|tool_order|file_exists|llm|baseline) : ;; *) nbad=$((nbad+1)); echo "   bad grader type '$t': $g" ;; esac
      w="$(sed -n '2,8s/^weight: *//p' "$g" | head -1)"   # claude plugin eval rejects weight <= 0 (the whole case fails to load)
      [ -z "$w" ] || python3 -c "import sys; sys.exit(not float(sys.argv[1]) > 0)" "$w" 2>/dev/null || { nbad=$((nbad+1)); echo "   weight must be > 0: $g"; }
    done
  done < <(find "$SU" -name prompt.md -not -path '*/results/*')
  check "P1: plugin-eval suites exist ($ncase cases)" '[ "$ncase" -ge 1 ]'
  check "P2: every case has ≥1 grader of a known type, weights > 0 ($nbad bad)" '[ "$nbad" = 0 ]'
fi

# ── A: plugin-eval.sh auth profile (K-17). The refusals exit before any copy or model call; a run under `plan` and
#    one under `api` are the same script path past this point, so these pin the only branch that differs.
PE="$ROOT/evals/plugin-eval.sh"
env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN bash "$PE" --auth api --case none >/dev/null 2>&1; rc=$?
check "A1: plugin-eval --auth api without a key is refused before anything runs (rc=$rc)" '[ "$rc" = 2 ]'
bash "$PE" --auth bogus --case none >/dev/null 2>&1; rc=$?
check "A2: plugin-eval --auth takes plan|api|auto only (rc=$rc)" '[ "$rc" = 2 ]'
check "A3: plugin-eval --auth plan drops the API key env, so the run uses the subscription login" \
  'grep -q "if \[ \"\$AUTH\" = plan \]; then unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN; fi" "$PE"'
check "A4: run-meta.json records auth_mode" 'grep -q "auth_mode" "$PE"'

echo "EVAL-HARNESS-TESTS: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
