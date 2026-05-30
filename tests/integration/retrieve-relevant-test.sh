#!/usr/bin/env bash
# retrieve-relevant-test.sh — Phase 4 proving tests (JIT relevance retrieval 4.1 +
# usefulness prior 4.3). Deterministic, NO model calls, runs in a mktemp sandbox.
# Wired into tests/run-all.sh as section L19.
set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd -P)"
RETR="$PLUGIN_ROOT/skills/learn/scripts/retrieve-relevant.sh"
UPD="$PLUGIN_ROOT/skills/learn/scripts/update-usefulness.sh"
PROP="$PLUGIN_ROOT/skills/learn/scripts/propose-rules.sh"
FIN="$PLUGIN_ROOT/bin/claudehut-finish"
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

# --- Case 13: 4.2 MCP ingestion — an MCP-only entity is retrieved (model-free) ---
d="$(mk no)"
printf '{"category":"pattern","title":"Unrelated local note","files_touched":[],"tags":["zzz"],"ts":"2026-01-01T00:00:00Z","task_id":"loc"}\n' > "$d/.claudehut/memory/learnings.jsonl"
# Real server format (verified vs saveGraph): NDJSON of entity + relation lines.
{ printf '{"type":"entity","name":"MapStruct null gotcha","entityType":"gotcha","observations":["content:x","tag:mapstruct","tag:mapping","file:src/main/java/com/example/mapper/X.java","ts:2026-02-01T00:00:00Z"]}\n';
  printf '{"type":"relation","from":"MapStruct null gotcha","to":"X","relationType":"touches"}\n'; } > "$d/.claudehut/memory/mcp-graph.json"
printf '%s' "$(bash "$RETR" "$d" "Add a MapStruct mapper" t-mcp 5)" | grep -qi 'MapStruct null gotcha' \
  && pass "L19.13 4.2 MCP entity retrieved; relation line ignored (model-free read, real saveGraph format)" || fail "L19.13" "MCP entity not surfaced"
rm -rf "$d"

# --- Case 14: 4.2 dedup — same key in JSONL + MCP → counted ONCE, JSONL wins ---
d="$(mk no)"
printf '{"category":"pattern","title":"Dup Mapper","files_touched":["src/main/java/com/example/mapper/D.java"],"tags":["mapstruct"],"ts":"2026-01-01T00:00:00Z","task_id":"jsonl-copy"}\n' > "$d/.claudehut/memory/learnings.jsonl"
printf '{"type":"entity","name":"Dup Mapper","entityType":"pattern","observations":["tag:mapstruct","file:src/main/java/com/example/mapper/D.java","ts:2026-02-01T00:00:00Z"]}\n' > "$d/.claudehut/memory/mcp-graph.json"
n="$(bash "$RETR" "$d" "mapstruct mapper" t-dup 5 | grep -c 'Dup Mapper')"
win="$(bash "$RETR" "$d" "mapstruct mapper" t-dup 5 | grep 'Dup Mapper' | grep -oE 'jsonl-copy|`mcp`' | head -1)"
{ [[ "$n" == "1" ]] && [[ "$win" == "jsonl-copy" ]]; } && pass "L19.14 4.2 dedup: shared key counted once, learnings.jsonl wins over MCP mirror" || fail "L19.14" "n=$n win=$win"
rm -rf "$d"

# --- Cases 15-17: 4.5 meta-learning proposals (dedup on signature) ---
d="$(mktemp -d)"; mkdir -p "$d/.claudehut/memory"
cat > "$d/.claudehut/memory/learnings.jsonl" <<'J'
{"category":"anti-pattern","title":"Blocking in reactive","content":"no blocking in webflux","signature":"sha256:aaa","tags":["webflux"],"task_id":"t1"}
{"category":"anti-pattern","title":"Blocking in reactive","content":"no blocking in webflux","signature":"sha256:aaa","tags":["webflux"],"task_id":"t2"}
{"category":"anti-pattern","title":"Blocking in reactive","content":"no blocking in webflux","signature":"sha256:aaa","tags":["webflux"],"task_id":"t3"}
{"category":"pattern","title":"Fine pattern","content":"ok","signature":"sha256:bbb","task_id":"t4"}
J
CLAUDE_PROJECT_DIR="$d" bash "$PROP" 3 >/dev/null
[[ "$(ls "$d/.claudehut/proposals/" 2>/dev/null | wc -l | tr -d ' ')" == "1" ]] && pass "L19.15 4.5 recurring anti-pattern (>=3) -> 1 proposal" || fail "L19.15" "proposals=$(ls "$d/.claudehut/proposals/" 2>/dev/null|wc -l)"
CLAUDE_PROJECT_DIR="$d" bash "$PROP" 3 >/dev/null
[[ "$(ls "$d/.claudehut/proposals/" 2>/dev/null | wc -l | tr -d ' ')" == "1" ]] && pass "L19.16 4.5 idempotent rerun (dedup on signature -> no duplicate)" || fail "L19.16" "after rerun=$(ls "$d/.claudehut/proposals/" 2>/dev/null|wc -l)"
d2="$(mktemp -d)"; mkdir -p "$d2/.claudehut/memory"
printf '{"category":"anti-pattern","title":"Rare","content":"x","signature":"sha256:ccc","task_id":"t1"}\n' > "$d2/.claudehut/memory/learnings.jsonl"
CLAUDE_PROJECT_DIR="$d2" bash "$PROP" 3 >/dev/null
[[ "$(ls "$d2/.claudehut/proposals/" 2>/dev/null | wc -l | tr -d ' ')" == "0" ]] && pass "L19.17 4.5 below-threshold anti-pattern -> no proposal" || fail "L19.17" "proposals created below K"
rm -rf "$d" "$d2"

# --- Case 18: 4.4 finish --abandon records the fail signal + prunes the retrieval log ---
d="$(mktemp -d)"; ( cd "$d" && git init -q && git config user.email t@t && git config user.name t && git checkout -q -b feature/ab 2>/dev/null )
mkdir -p "$d/.claudehut/memory" "$d/.claudehut/findings" "$d/.claudehut/state"
cp "$FIX/learnings-sample.jsonl" "$d/.claudehut/memory/learnings.jsonl"
printf '{"task_id":"feature-ab","ts":"t","sigs":["mapstruct mapper added: ordermapper:pattern"]}\n' > "$d/.claudehut/state/retrieval-feature-ab.json"
printf '{"decision":"fail"}\n' > "$d/.claudehut/findings/feature-ab-findings.json"
( cd "$d" && git add -A && git commit -qm base >/dev/null 2>&1 )
echo yes | CLAUDE_PROJECT_DIR="$d" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$FIN" --abandon >/dev/null 2>&1
uf="$(jq -r '."mapstruct mapper added: ordermapper:pattern".useful' "$d/.claudehut/memory/usefulness.json" 2>/dev/null)"
ud="$(jq -r '."mapstruct mapper added: ordermapper:pattern".used' "$d/.claudehut/memory/usefulness.json" 2>/dev/null)"
{ [[ "$ud" == "1" && "$uf" == "0" ]] && [[ ! -f "$d/.claudehut/state/retrieval-feature-ab.json" ]]; } \
  && pass "L19.18 4.4 finish --abandon: fail signal recorded (used++,useful+0) + retrieval log pruned" \
  || fail "L19.18" "used=$ud useful=$uf logExists=$([[ -f "$d/.claudehut/state/retrieval-feature-ab.json" ]] && echo yes || echo no)"
rm -rf "$d"

# --- Case 19: 4.2 reader accepts the server's DEFAULT filename (memory.jsonl) ---
d="$(mk no)"
printf '{"category":"pattern","title":"Unrelated","files_touched":[],"tags":["zzz"],"ts":"2026-01-01T00:00:00Z","task_id":"loc"}\n' > "$d/.claudehut/memory/learnings.jsonl"
printf '{"type":"entity","name":"Flyway concurrent index gotcha","entityType":"gotcha","observations":["content:y","tag:flyway","tag:migration","file:src/main/resources/db/migration/V9__x.sql","ts:2026-02-02T00:00:00Z"]}\n' > "$d/.claudehut/memory/memory.jsonl"
printf '%s' "$(bash "$RETR" "$d" "Add a Flyway migration" t-mem 5)" | grep -qi 'Flyway concurrent index gotcha' \
  && pass "L19.19 4.2 reader falls back to the server default name memory.jsonl" || fail "L19.19" "memory.jsonl fallback not read"
rm -rf "$d"

# --- Case 20: verify-retrieval via the git-diff fallback (empty intent + NO plan) ---
# This is the exact real-run failure the seeded $ A/B surfaced: the verify dispatch
# passes "" intent and quick mode has no plan → retrieval stubbed. The diff fallback
# must query by the branch's changed files so a verify dispatch still retrieves.
d="$(mktemp -d)"; ( cd "$d" && git init -q && git config user.email t@t && git config user.name t )
mkdir -p "$d/.claudehut/memory" "$d/src/main/java/com/example/mapper"
cp "$FIX/learnings-sample.jsonl" "$d/.claudehut/memory/learnings.jsonl"
printf 'A\n' > "$d/src/main/java/com/example/mapper/NewMapper.java"
( cd "$d" && git add -A && git commit -qm base >/dev/null 2>&1 )
printf 'B\n' > "$d/src/main/java/com/example/mapper/NewMapper.java"
( cd "$d" && git add -A && git commit -qm "build: touch mapper package" >/dev/null 2>&1 )
out="$(bash "$RETR" "$d" "" t-diff 5)"
printf '%s' "$out" | grep -q 'none yet' \
  && fail "L19.20" "diff-fallback stubbed despite a package-matching diff: $out" \
  || pass "L19.20 verify-retrieval: empty intent + no plan -> git-diff query surfaces package-matched learnings"
rm -rf "$d"

# --- Case 21: guard — an unrelated diff must NOT surface anything (no false positives) ---
d="$(mktemp -d)"; ( cd "$d" && git init -q && git config user.email t@t && git config user.name t )
mkdir -p "$d/.claudehut/memory" "$d/totally/unrelated/place"
cp "$FIX/learnings-sample.jsonl" "$d/.claudehut/memory/learnings.jsonl"
printf 'A\n' > "$d/totally/unrelated/place/Z.txt"
( cd "$d" && git add -A && git commit -qm base >/dev/null 2>&1 )
printf 'B\n' > "$d/totally/unrelated/place/Z.txt"
( cd "$d" && git add -A && git commit -qm "touch unrelated path" >/dev/null 2>&1 )
out="$(bash "$RETR" "$d" "" t-none 5)"
printf '%s' "$out" | grep -q 'none yet' \
  && pass "L19.21 verify-retrieval guard: empty intent + no plan + no package match -> stub (no false positives)" \
  || fail "L19.21" "surfaced learnings for an unrelated diff: $out"
rm -rf "$d"

# --- Case 23: early-phase dispatch-prompt WITH intent → non-stub (the full-route path) ---
# The brainstorm/spec/plan/build dispatch-prompts pass the USER INTENT as "$ARGUMENTS".
# This is the PRIMARY retrieval path (intent-driven, before any plan/diff exists).
# Proves it deterministically — so a paid full-route run is NOT needed to show
# "retrieval fires with intent"; it would only test whether the headless orchestrator
# actually invokes dispatch-prompt.sh with the intent (a seam question, not this).
d="$(mktemp -d)"; mkdir -p "$d/.claudehut/memory"
cp "$FIX/learnings-sample.jsonl" "$d/.claudehut/memory/learnings.jsonl"
printf -- '- web: mvc\n' > "$d/.claudehut/memory/stack-signals.md"
out="$(CLAUDE_PROJECT_DIR="$d" CLAUDEHUT_TASK_ID=t-bs CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
  bash "$PLUGIN_ROOT/skills/brainstorm/scripts/dispatch-prompt.sh" "Add a MapStruct mapper for OrderDto" 2>/dev/null)"
printf '%s' "$out" | grep -A4 'Relevant learnings' | grep -qiE 'mapstruct' \
  && pass "L19.23 early-phase (brainstorm) dispatch-prompt with intent → non-stub (mapstruct surfaced)" \
  || fail "L19.23" "brainstorm dispatch-prompt stubbed despite intent+corpus: $(printf '%s' "$out" | grep -A2 'Relevant learnings')"
rm -rf "$d"

echo ""
echo "retrieve-relevant: Pass=$PASS Fail=$FAIL"
[[ "$FAIL" -gt 0 ]] && { printf '  - %s\n' "${FAIL_LIST[@]}"; exit 1; } || exit 0
