#!/usr/bin/env bash
# retrieve-relevant-test.sh — Phase 4 proving tests (JIT relevance retrieval 4.1 +
# usefulness prior 4.3). Deterministic, NO model calls, runs in a mktemp sandbox.
# Wired into tests/run-all.sh as section L19.
set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd -P)"
RETR="$PLUGIN_ROOT/skills/learn/scripts/retrieve-relevant.sh"
UPD="$PLUGIN_ROOT/skills/learn/scripts/update-usefulness.sh"
FIX="$PLUGIN_ROOT/tests/fixtures"
PASS=0; FAIL=0; declare -a FAIL_LIST=()
pass() { printf "  \033[32m✓\033[0m %s\n" "$1"; PASS=$((PASS+1)); }
fail() { printf "  \033[31m✗\033[0m %s :: %s\n" "$1" "$2"; FAIL=$((FAIL+1)); FAIL_LIST+=("$1: $2"); }

# Fresh sandbox seeded with the learnings fixture. $1=with-plan (yes|no).
mk() {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/.claudehut/memory" "$d/.claudehut/plans" "$d/.claudehut/findings" "$d/.claudehut/state"
  cp "$FIX/learnings-sample.jsonl" "$d/.claudehut/memory/learnings.jsonl"
  printf -- '- web: mvc\n- orm: jpa\n- mapper: mapstruct\n' > "$d/.claudehut/memory/stack-signals.md"
  if [[ "${1:-no}" == "yes" ]]; then
    printf '# Plan\n## Task 1\n- create: `src/main/java/com/example/mapper/InvoiceMapper.java`\n' \
      > "$d/.claudehut/plans/t-task-plan.md"
  fi
  echo "$d"
}
ids() { grep -oE 't-[a-z0-9]+' || true; }  # extract task_ids from retrieve output, in order

Q="Add a MapStruct mapper for InvoiceDto"

# --- Case 1: exact ranked order (mapstruct dominant), floor + tombstone exclusion ---
d="$(mk yes)"
out="$(bash "$RETR" "$d" "$Q" t-task 5)"
order="$(printf '%s' "$out" | ids | tr '\n' ' ')"
[[ "$order" == "t-m3 t-m2 t-m1 " ]] && pass "L19.1 exact ranked order (t-m3 t-m2 t-m1, ts-desc tiebreak on equal R)" || fail "L19.1" "order was: $order"
printf '%s' "$out" | grep -qE 't-f1|t-g1|t-tomb' && fail "L19.1b" "flyway/generic/tombstone leaked (floor/tombstone filter broken)" || pass "L19.1b floor excludes flyway+generic; tombstone filtered"
rm -rf "$d"

# --- Case 2: determinism (run twice → byte-identical) ---
d="$(mk yes)"
a="$(bash "$RETR" "$d" "$Q" t-task 5)"; b="$(bash "$RETR" "$d" "$Q" t-task 5)"
[[ "$a" == "$b" ]] && pass "L19.2 deterministic (byte-identical across runs)" || fail "L19.2" "non-deterministic output"
rm -rf "$d"

# --- Case 3: absent plan → S_path=0, still ranks by tag/title ---
d="$(mk no)"
out="$(bash "$RETR" "$d" "$Q" t-noplan 5)"; rc=$?
{ [[ $rc -eq 0 ]] && printf '%s' "$out" | grep -q '## Relevant learnings' && printf '%s' "$out" | grep -q 't-m'; } \
  && pass "L19.3 absent plan degrades to tag/title ranking (mapstruct still surfaces)" || fail "L19.3" "rc=$rc out=$out"
rm -rf "$d"

# --- Case 4: absent learnings.jsonl → stub ---
d="$(mktemp -d)"; mkdir -p "$d/.claudehut/memory"
out="$(bash "$RETR" "$d" "$Q" t-x 5)"
printf '%s' "$out" | grep -q 'none yet' && pass "L19.4 absent learnings.jsonl → stub + exit 0" || fail "L19.4" "no stub: $out"
rm -rf "$d"

# --- Case 5: retrieval log appended with lower(title):category sigs ---
d="$(mk yes)"
bash "$RETR" "$d" "$Q" t-task 5 >/dev/null
log="$d/.claudehut/state/retrieval-t-task.json"
{ [[ -s "$log" ]] && jq -e '.sigs | length > 0' "$log" >/dev/null 2>&1 \
  && jq -e '.sigs | all(test(":"))' "$log" >/dev/null 2>&1; } \
  && pass "L19.5 retrieval log appended with sigs (lower(title):category)" || fail "L19.5" "log bad: $(cat "$log" 2>/dev/null)"
rm -rf "$d"

# --- Case 6: update-usefulness pass credit → used=1,useful=1 + marker ---
d="$(mk yes)"
printf '{"task_id":"t-task","ts":"t","sigs":["mapstruct mapper added: ordermapper:pattern","mapstruct mapper added: usermapper:pattern"]}\n' > "$d/.claudehut/state/retrieval-t-task.json"
printf '{"decision":"pass"}\n' > "$d/.claudehut/findings/t-task-findings.json"
CLAUDE_PROJECT_DIR="$d" bash "$UPD" t-task >/dev/null
uf="$(jq -r '."mapstruct mapper added: ordermapper:pattern".useful' "$d/.claudehut/memory/usefulness.json" 2>/dev/null)"
ud="$(jq -r '."mapstruct mapper added: ordermapper:pattern".used' "$d/.claudehut/memory/usefulness.json" 2>/dev/null)"
{ [[ "$uf" == "1" && "$ud" == "1" ]] && [[ -f "$d/.claudehut/state/usefulness-scored-t-task.marker" ]]; } \
  && pass "L19.6 pass credit → used=1,useful=1 + marker" || fail "L19.6" "used=$ud useful=$uf"
rm -rf "$d"

# --- Case 7: fail-path → used++ only (proves 4.4 seam is wired, not dead) ---
d="$(mk yes)"
printf '{"task_id":"t-task","ts":"t","sigs":["mapstruct mapper added: ordermapper:pattern"]}\n' > "$d/.claudehut/state/retrieval-t-task.json"
printf '{"decision":"fail"}\n' > "$d/.claudehut/findings/t-task-findings.json"
CLAUDE_PROJECT_DIR="$d" bash "$UPD" t-task >/dev/null
uf="$(jq -r '."mapstruct mapper added: ordermapper:pattern".useful' "$d/.claudehut/memory/usefulness.json" 2>/dev/null)"
ud="$(jq -r '."mapstruct mapper added: ordermapper:pattern".used' "$d/.claudehut/memory/usefulness.json" 2>/dev/null)"
[[ "$uf" == "0" && "$ud" == "1" ]] && pass "L19.7 fail-path → used=1,useful=0 (downward-pressure branch wired; 4.4 seam)" || fail "L19.7" "used=$ud useful=$uf"
rm -rf "$d"

# --- Case 8: idempotency (second run no-ops) ---
d="$(mk yes)"
printf '{"task_id":"t-task","ts":"t","sigs":["mapstruct mapper added: ordermapper:pattern"]}\n' > "$d/.claudehut/state/retrieval-t-task.json"
printf '{"decision":"pass"}\n' > "$d/.claudehut/findings/t-task-findings.json"
CLAUDE_PROJECT_DIR="$d" bash "$UPD" t-task >/dev/null
CLAUDE_PROJECT_DIR="$d" bash "$UPD" t-task >/dev/null
ud="$(jq -r '."mapstruct mapper added: ordermapper:pattern".used' "$d/.claudehut/memory/usefulness.json" 2>/dev/null)"
[[ "$ud" == "1" ]] && pass "L19.8 idempotent (marker blocks double-credit; used stays 1)" || fail "L19.8" "used=$ud after 2 runs"
rm -rf "$d"

# --- Case 9: absent retrieval log → exit 0, sidecar untouched ---
d="$(mk yes)"
printf '{"decision":"pass"}\n' > "$d/.claudehut/findings/t-task-findings.json"
CLAUDE_PROJECT_DIR="$d" bash "$UPD" t-task >/dev/null; rc=$?
{ [[ $rc -eq 0 ]] && [[ ! -f "$d/.claudehut/memory/usefulness.json" ]]; } \
  && pass "L19.9 absent retrieval log → exit 0, sidecar not created" || fail "L19.9" "rc=$rc sidecar=$(ls "$d/.claudehut/memory/usefulness.json" 2>/dev/null)"
rm -rf "$d"

# --- Case 10: malformed learnings.jsonl → EXACTLY the stub, no partial bullets ---
d="$(mktemp -d)"; mkdir -p "$d/.claudehut/memory"
printf '{"valid":1}\nNOT JSON {{{\n' > "$d/.claudehut/memory/learnings.jsonl"
out="$(bash "$RETR" "$d" "anything" t-x 5)"; rc=$?
{ [[ $rc -eq 0 ]] && printf '%s' "$out" | grep -q 'none yet' && ! printf '%s' "$out" | grep -qE '^- '; } \
  && pass "L19.10 malformed input → exact stub, no partial output (self-degrading)" || fail "L19.10" "rc=$rc out=$out"
rm -rf "$d"

# --- Case 11: S_prior is the SOLE discriminant (mandatory — without it, weight=0 passes) ---
d="$(mk yes)"
cp "$FIX/usefulness-sample.json" "$d/.claudehut/memory/usefulness.json"   # m1 useful 9/10, m2 useful 1/10
order="$(bash "$RETR" "$d" "$Q" t-task 5 | ids | tr '\n' ' ')"
# Cold order is t-m3 t-m2 t-m1 (ts desc). With m1 high / m2 low prior, m1 must overtake m2.
m1pos="$(printf '%s' "$order" | tr ' ' '\n' | grep -n '^t-m1$' | cut -d: -f1)"
m2pos="$(printf '%s' "$order" | tr ' ' '\n' | grep -n '^t-m2$' | cut -d: -f1)"
{ [[ -n "$m1pos" && -n "$m2pos" ]] && [[ "$m1pos" -lt "$m2pos" ]]; } \
  && pass "L19.11 S_prior changes ranking: high-useful t-m1 outranks low-useful t-m2 (order: $order)" \
  || fail "L19.11" "S_prior did NOT reorder (m1@$m1pos m2@$m2pos): $order — usefulness weight may be dead"
rm -rf "$d"

# --- Case 12: full round-trip on REAL script output (advisor blocker) ---
# retrieve WRITES the log → update CREDITS on pass → retrieve RE-READS a higher S_prior.
# No hand-authored keys: proves writer==reader key derivation end-to-end.
d="$(mk yes)"
bash "$RETR" "$d" "$Q" t-task 5 >/dev/null                       # writes retrieval log (real sigs)
printf '{"decision":"pass"}\n' > "$d/.claudehut/findings/t-task-findings.json"
CLAUDE_PROJECT_DIR="$d" bash "$UPD" t-task >/dev/null            # credits using ITS key derivation
# every logged sig must now exist in usefulness.json (writer key == reader key)
miss="$(jq -r --slurpfile u <(jq '[keys[]]' "$d/.claudehut/memory/usefulness.json") \
  '.sigs[] | select(([.] - $u[0]) | length > 0)' "$d/.claudehut/state/retrieval-t-task.json" 2>/dev/null | head -1)"
credited="$(jq -r '."mapstruct mapper added: ordermapper:pattern".useful' "$d/.claudehut/memory/usefulness.json" 2>/dev/null)"
{ [[ -z "$miss" ]] && [[ "$credited" == "1" ]]; } \
  && pass "L19.12 round-trip: every retrieved sig credited (writer key == reader key — 4.3 loop real)" \
  || fail "L19.12" "key drift — unmatched sig '$miss' / credited=$credited"
rm -rf "$d"

echo ""
echo "retrieve-relevant: Pass=$PASS Fail=$FAIL"
[[ "$FAIL" -gt 0 ]] && { printf '  - %s\n' "${FAIL_LIST[@]}"; exit 1; } || exit 0
