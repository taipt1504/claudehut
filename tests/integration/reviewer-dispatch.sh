#!/usr/bin/env bash
# tests/integration/reviewer-dispatch.sh
#
# Phase-0 reviewer-shard + aggregate contract:
#   - reviewers write standalone shards .claudehut/findings/<id>/reviewer-<short>.json
#       shard shape: {"reviewer":"<full-agent-name>","completed_at":"...","findings":[ {severity,...} ]}
#   - SubagentStop hook writes a completion MARKER into .reviewers[<full-name>].completed_at
#   - aggregate-findings.sh <task-id> merges shards + verify stanza, computes totals,
#       applies the high==0 rule, zero-shard => fail.
# Catches gap-a (state.sh round-trip) + gap-c (high==0; old high<3 enshrined a bug).

set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0; FAIL=0
declare -a FAIL_LIST=()

pass() { printf "  \033[32m✓\033[0m %s\n" "$1"; PASS=$((PASS+1)); }
fail() { printf "  \033[31m✗\033[0m %s :: %s\n" "$1" "$2"; FAIL=$((FAIL+1)); FAIL_LIST+=("$1: $2"); }

TMPDIR=$(mktemp -d)
cd "$TMPDIR"
git init -q
git config user.email test@test
git config user.name Test
git checkout -q -b feature/dispatch 2>/dev/null
mkdir -p .claudehut/{specs,plans,memory,findings,reuse-scans}
TASK_ID=feature-dispatch

export CLAUDE_PROJECT_DIR="$TMPDIR"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
AGG="$PLUGIN_ROOT/skills/verify-review/scripts/aggregate-findings.sh"
findings_file=".claudehut/findings/$TASK_ID-findings.json"
shard_dir=".claudehut/findings/$TASK_ID"
mkdir -p "$shard_dir"

echo "===== REVIEWER SHARD + AGGREGATE CONTRACT ====="
echo ""

reviewers="claudehut-reviewer-security claudehut-reviewer-perf claudehut-reviewer-db claudehut-reviewer-reactive claudehut-reviewer-style claudehut-reviewer-mapping"

# Seed a passing verify stanza (so decision is driven by findings, not verify).
printf '{"verify":{"build":{"status":"pass"},"test":{"status":"pass"}},"reviewers":{}}\n' > "$findings_file"

# SubagentStop fires a completion marker for each reviewer.
for r in $reviewers; do
  echo "{\"agent_type\":\"$r\"}" | bash "$PLUGIN_ROOT/hooks/subagent-stop.sh" >/dev/null
done
[[ -f "$findings_file" ]] && pass "findings.json present" || fail "findings.json" "missing"
for r in $reviewers; do
  if jq -e --arg r "$r" '.reviewers[$r].completed_at' "$findings_file" >/dev/null 2>&1; then
    pass "marker recorded: $r"
  else fail "marker" "$r missing in findings"; fi
done

# gap-a: state.sh round-trip path equality.
canonical="$(bash -c 'source "$1/hooks/lib/state.sh"; CLAUDE_PROJECT_DIR="$3" claudehut_findings_doc "$2"' _ "$PLUGIN_ROOT" "$TASK_ID" "$TMPDIR")"
expected_abs="$TMPDIR/.claudehut/findings/$TASK_ID-findings.json"
[[ "$canonical" == "$expected_abs" ]] && pass "gap-a: claudehut_findings_doc path round-trips" \
  || fail "gap-a: claudehut_findings_doc" "expected '$expected_abs' got '$canonical'"

_decision() { bash -c 'source "$1/hooks/lib/state.sh"; CLAUDE_PROJECT_DIR="$3" claudehut_findings_decision "$2"' _ "$PLUGIN_ROOT" "$TASK_ID" "$TMPDIR"; }

# ---- gap-c case 1: 1 High → fail (high==0 rule, NOT high<3) ----
cat > "$shard_dir/reviewer-security.json" <<'S'
{"reviewer":"claudehut-reviewer-security","completed_at":"t","findings":[{"severity":"high","category":"security","file":"A.java","line":10,"title":"auth missing","detail":"endpoint lacks auth","suggestion":"add @PreAuthorize"}]}
S
cat > "$shard_dir/reviewer-perf.json" <<'S'
{"reviewer":"claudehut-reviewer-perf","completed_at":"t","findings":[{"severity":"medium","category":"perf","file":"A.java","line":20,"title":"n+1","detail":"lazy in loop","suggestion":"@EntityGraph"}]}
S
cat > "$shard_dir/reviewer-style.json" <<'S'
{"reviewer":"claudehut-reviewer-style","completed_at":"t","findings":[{"severity":"low","category":"style","file":"Z.java","line":5,"title":"record","detail":"final fields","suggestion":"convert"}]}
S
bash "$AGG" "$TASK_ID" >/dev/null
pass "aggregator ran (case 1: 1 High)"
[[ "$(jq -r '.totals.critical' "$findings_file")" == "0" ]] && pass "case1 critical=0" || fail "case1 critical" "got $(jq -r '.totals.critical' "$findings_file")"
[[ "$(jq -r '.totals.high'     "$findings_file")" == "1" ]] && pass "case1 high=1"     || fail "case1 high"     "got $(jq -r '.totals.high' "$findings_file")"
[[ "$(jq -r '.totals.medium'   "$findings_file")" == "1" ]] && pass "case1 medium=1 (shard reader works)" || fail "case1 medium" "got $(jq -r '.totals.medium' "$findings_file")"
[[ "$(jq -r '.totals.low'      "$findings_file")" == "1" ]] && pass "case1 low=1"       || fail "case1 low"      "got $(jq -r '.totals.low' "$findings_file")"
[[ "$(jq -r '.decision' "$findings_file")" == "fail" ]] && pass "case1 decision=fail (1 high violates high==0)" || fail "case1 decision" "expected fail, got $(jq -r '.decision' "$findings_file")"
[[ "$(_decision)" == "fail" ]] && pass "gap-a: claudehut_findings_decision round-trip=fail" || fail "gap-a decision" "got $(_decision)"

# ---- gap-c case 2: 0 critical / 0 high → pass ----
rm -f "$shard_dir"/reviewer-*.json
cat > "$shard_dir/reviewer-perf.json" <<'S'
{"reviewer":"claudehut-reviewer-perf","completed_at":"t","findings":[{"severity":"medium","category":"perf","file":"A.java","line":5,"title":"minor","detail":"low traffic","suggestion":"maybe"}]}
S
cat > "$shard_dir/reviewer-style.json" <<'S'
{"reviewer":"claudehut-reviewer-style","completed_at":"t","findings":[{"severity":"low","category":"style","file":"B.java","line":8,"title":"naming","detail":"camelCase","suggestion":"rename"}]}
S
bash "$AGG" "$TASK_ID" >/dev/null
pass "aggregator ran (case 2: 0 critical / 0 high)"
[[ "$(jq -r '.totals.high' "$findings_file")" == "0" ]] && pass "case2 high=0" || fail "case2 high" "got $(jq -r '.totals.high' "$findings_file")"
[[ "$(jq -r '.totals.medium' "$findings_file")" == "1" ]] && pass "case2 medium=1 (discriminating)" || fail "case2 medium" "got $(jq -r '.totals.medium' "$findings_file")"
[[ "$(jq -r '.totals.low' "$findings_file")" == "1" ]] && pass "case2 low=1 (discriminating)" || fail "case2 low" "got $(jq -r '.totals.low' "$findings_file")"
[[ "$(jq -r '.decision' "$findings_file")" == "pass" ]] && pass "case2 decision=pass (0 crit + 0 high)" || fail "case2 decision" "expected pass, got $(jq -r '.decision' "$findings_file")"
[[ "$(_decision)" == "pass" ]] && pass "gap-a: round-trip decision=pass" || fail "gap-a decision2" "got $(_decision)"

# ---- zero-shard guard: no shards → fail (never a false pass) ----
rm -f "$shard_dir"/reviewer-*.json
bash "$AGG" "$TASK_ID" >/dev/null
[[ "$(jq -r '.decision' "$findings_file")" == "fail" ]] && pass "zero-shard guard → decision=fail" || fail "zero-shard" "expected fail, got $(jq -r '.decision' "$findings_file")"

# ---- critical → fail even with passing verify ----
cat > "$shard_dir/reviewer-security.json" <<'S'
{"reviewer":"claudehut-reviewer-security","completed_at":"t","findings":[{"severity":"critical","category":"security","file":"x","line":1,"title":"RCE","detail":"rce","suggestion":"fix"}]}
S
bash "$AGG" "$TASK_ID" >/dev/null
[[ "$(jq -r '.decision' "$findings_file")" == "fail" ]] && pass "critical → decision=fail" || fail "critical" "expected fail, got $(jq -r '.decision' "$findings_file")"

cd "$PLUGIN_ROOT"
rm -rf "$TMPDIR"

echo ""
echo "===== SUMMARY ====="
printf "Total: %d   \033[32mPass: %d\033[0m   \033[31mFail: %d\033[0m\n" $((PASS+FAIL)) "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  echo ""; echo "FAILURES:"; for f in "${FAIL_LIST[@]}"; do echo "  - $f"; done
  exit 1
fi
exit 0
