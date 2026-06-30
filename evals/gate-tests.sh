#!/usr/bin/env bash
# Deterministic unit tests for the ClaudeHut enforcement spine (no Claude required).
# Feeds crafted state.json + hook stdin to the gate scripts and asserts their decisions.
# Run: evals/gate-tests.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export CLAUDE_PLUGIN_ROOT="$ROOT"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   - $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL - $1"; }

new_proj() { TMP="$(mktemp -d)"; export CLAUDE_PROJECT_DIR="$TMP"; mkdir -p "$TMP/.claude/claudehut/state" "$TMP/.claude/claudehut/plans"; }
st() { "$ROOT/bin/claudehut-state" --session s "$@" >/dev/null; }
# WS-6: the Learn Stop-gate now checks a per-session learn-receipt (written by merge-learnings), not a
# non-empty learnings.jsonl. Helper writes a fresh receipt for session s.
mk_receipt() { mkdir -p "$CLAUDE_PROJECT_DIR/.claude/claudehut/state"; printf '{"ts":"2026-06-01T00:00:00Z","added":1,"merged":0}\n' > "$CLAUDE_PROJECT_DIR/.claude/claudehut/state/s.learn-receipt.json"; }
# review-rigor v0.5: set-review pass requires --evidence review.md (coverage table + test summary).
# Helper writes a valid evidence file under the canonical store and passes it.
review_pass() {
  local ev="$CLAUDE_PROJECT_DIR/.claude/claudehut/tasks/0001-x/review.md"
  mkdir -p "$(dirname "$ev")"
  printf '# Review\n| Item | Status | Evidence |\n|---|---|---|\n| jpa fetch | ✓ satisfied | Foo.java:1 |\n\nTests: ./gradlew test — 12 passed\n' > "$ev"
  "$ROOT/bin/claudehut-state" --session s set-review pass --evidence "$ev" >/dev/null
}
denies()  { echo "$2" | "$ROOT/scripts/gate-write.sh" | jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null 2>&1; }
allows()  { [ -z "$(echo "$2" | "$ROOT/scripts/gate-write.sh")" ]; }
blocks()  { echo "$2" | "$ROOT/scripts/gate-done.sh" | jq -e '.decision=="block"' >/dev/null 2>&1; }
done_ok() { [ -z "$(echo "$2" | "$ROOT/scripts/gate-done.sh")" ]; }

PROD='{"session_id":"s","tool_input":{"file_path":"/p/src/main/java/Foo.java"}}'

echo "== state writer =="
new_proj; st set-phase brainstorm; jq -e '.phase=="brainstorm" and .session=="s"' "$CLAUDE_PROJECT_DIR/.claude/claudehut/state/s.json" >/dev/null && ok "writes valid per-session state" || bad "state write"
rm -rf "$TMP"

echo "== gate-write (action gate) =="
new_proj; st set-phase brainstorm
chd="$CLAUDE_PROJECT_DIR/.claude/claudehut"; mkdir -p "$chd/specs" "$chd/plans"
denies x "$PROD" && ok "deny: no reuse_scan" || bad "deny: no reuse_scan"
printf '| Dimension | Existing | Decision | Fit | Impact | Effort |\n| x | none | new | 1 | low | S |\n' > "$chd/reuse-scan-x.md"; st set-reuse-scan --artifact "$chd/reuse-scan-x.md"
denies x "$PROD" && ok "deny: reuse ok, no spec" || bad "deny: no spec"
printf '## 1. Problem & Context\nx\n## 5. Acceptance Criteria\n- AC-001 GIVEN a WHEN b THEN c\n## 9. Decision Record\nOutcome: A\n' > "$chd/specs/x.md"; st set-spec "$chd/specs/x.md"
denies x "$PROD" && ok "deny: spec ok, no plan" || bad "deny: no plan"
printf '## 3. Implementation Flow\nA->B->C\n**T-001 sketch**: foo() control-flow\n## 4. Task Breakdown\n| ID | Goal |\n| T-001 | x |\n' > "$chd/plans/x.md"; st set-plan "$chd/plans/x.md"
# Issue-1 skill rail: artifacts alone no longer open the gate — the implement skill must be invoked.
denies x "$PROD" && ok "deny: reuse+spec+plan set but implement skill NOT invoked (skill rail)" || bad "deny: skill rail (full tier)"
st mark-skill implement
allows x "$PROD" && ok "allow: reuse+spec+plan + implement skill invoked" || bad "allow: all set + skill"
# template-structure validation — freeform spec/plan rejected by the state writer
echo freeform > "$chd/specs/bad.md"
"$ROOT/bin/claudehut-state" --session s set-spec "$chd/specs/bad.md" >/dev/null 2>&1 \
  && bad "tmpl: accepted freeform spec (no sections)" || ok "reject: freeform spec (no ## sections / Decision)"
echo prose-plan > "$chd/plans/bad.md"
"$ROOT/bin/claudehut-state" --session s set-plan "$chd/plans/bad.md" >/dev/null 2>&1 \
  && bad "tmpl: accepted freeform plan (no T-rows)" || ok "reject: freeform plan (no T-xxx rows)"
allows x '{"session_id":"s","tool_input":{"file_path":"/p/.claude/claudehut/specs/x.md"}}' && ok "allow: .claude/claudehut path" || bad "allow: claudehut path"
allows x '{"session_id":"s","tool_input":{"file_path":"/p/src/test/java/FooTest.java"}}' && ok "allow: test path" || bad "allow: test path"
st set-bypass true; allows x "$PROD" && ok "allow: bypass=true" || bad "allow: bypass"
rm -rf "$TMP"
# opt #4 — flag set but artifact FILE missing → still deny
new_proj; st set-phase brainstorm
st set-reuse-scan --artifact "$CLAUDE_PROJECT_DIR/.claude/claudehut/reuse-scan-missing.md"
denies x "$PROD" && ok "deny: reuse flag set but artifact file missing (#4)" || bad "deny: missing artifact"
rm -rf "$TMP"
# opt #2 — non-canonical artifact path rejected by the state writer
new_proj
"$ROOT/bin/claudehut-state" --session s set-spec /tmp/bare-spec.md >/dev/null 2>&1 \
  && bad "canon: accepted non-canonical spec path" || ok "reject: non-canonical artifact path (#2)"
"$ROOT/bin/claudehut-state" --session s set-phase plan --spec /tmp/bare.md >/dev/null 2>&1 \
  && bad "canon: set-phase --spec accepted non-canonical" || ok "reject: set-phase --spec non-canonical (P4)"
rm -rf "$TMP"
new_proj; allows x '{"session_id":"missing","tool_input":{"file_path":"/p/X.java"}}' && ok "allow: missing state fails open" || bad "fail-open"
rm -rf "$TMP"

echo "== gate-done (completion gate) =="
# opt #1 — armed-but-not-engaged (fresh brainstorm, no reuse/spec/plan) → Stop NOT blocked
new_proj; st set-phase brainstorm
done_ok x '{"session_id":"s","stop_hook_active":false}' && ok "allow: armed-but-not-engaged not blocked (#1)" || bad "engaged-guard"
rm -rf "$TMP"
new_proj; st set-profile feature; st set-phase implement
blocks x '{"session_id":"s","stop_hook_active":false}' && ok "block: review pending (engaged)" || bad "block: pending"
review_pass; blocks x '{"session_id":"s","stop_hook_active":false}' && ok "block: review pass but phase!=learn" || bad "block: phase!=learn"
mk_receipt
st set-phase learn; done_ok x '{"session_id":"s","stop_hook_active":false}' && ok "allow: review=pass + phase=learn + fresh learn-receipt" || bad "allow: done"
st set-review pending; done_ok x '{"session_id":"s","stop_hook_active":true}' && ok "allow: stop_hook_active cap" || bad "cap allow"
done_ok x '{"session_id":"none","stop_hook_active":false}' && ok "allow: missing state fails open (no block)" || bad "done fail-open"
rm -rf "$TMP"
# PARK-and-wait fail-open (0012): a Stop fired while a background subagent is still running (an UNPAIRED
# Agent tool_use in the transcript) is a park, not a completion attempt → fail open even with review
# pending. A transcript whose Agent tool_use is PAIRED (subagent finished) → the gate enforces normally.
new_proj; st set-profile feature; st set-phase implement   # review pending → would block without a park
TR_PEND="$TMP/pending.jsonl"
printf '%s\n%s\n' \
  '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Agent","id":"toolu_INFLIGHT"}]}}' \
  '{"type":"user","message":{"content":[{"type":"text","text":"waiting on reviewer"}]}}' > "$TR_PEND"
done_ok x "{\"session_id\":\"s\",\"stop_hook_active\":false,\"transcript_path\":\"$TR_PEND\"}" \
  && ok "allow: background subagent in flight (unpaired Agent) → park, fail open" || bad "park-wait: blocked while subagent running"
TR_DONE="$TMP/done.jsonl"
printf '%s\n%s\n' \
  '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Agent","id":"toolu_DONE"}]}}' \
  '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_DONE","content":"ok"}]}}' > "$TR_DONE"
blocks x "{\"session_id\":\"s\",\"stop_hook_active\":false,\"transcript_path\":\"$TR_DONE\"}" \
  && ok "block: all subagents finished (paired) → gate enforces (review pending)" || bad "park-wait: failed open with no in-flight subagent"
rm -rf "$TMP"
# tier-aware completion (Issue 4 × gate-done interaction — trivial skips Learn, must NOT wedge)
new_proj; st set-phase review; review_pass; st set-complexity trivial
done_ok x '{"session_id":"s","stop_hook_active":false}' && ok "allow: trivial tier — review=pass terminates WITHOUT Learn (no wedge)" || bad "trivial done without learn"
st set-complexity small
blocks x '{"session_id":"s","stop_hook_active":false}' && ok "block: small tier still requires Learn" || bad "small learn required"
rm -rf "$TMP"

echo "== gate-write: complexity tiers (Issue 4 safe-by-construction) =="
# helper: a real git repo as the project so the fast-lane bound (git diff) is computable
new_gitproj() {
  TMP="$(mktemp -d)"; export CLAUDE_PROJECT_DIR="$TMP"
  ( cd "$TMP" && git init -q && git config user.email t@t && git config user.name t \
    && mkdir -p src/main/java/com/x && echo 'class A{}' > src/main/java/com/x/A.java \
    && git add -A && git commit -qm base ) >/dev/null 2>&1
  mkdir -p "$TMP/.claude/claudehut"
}
PRODX='{"session_id":"s","tool_input":{"file_path":"'  # prefix; we append a path per-case

# small tier, reuse set, within bound (1 changed file), no sensitive path → ALLOW without spec/plan
# (after the implement skill is invoked — the skill rail applies in EVERY tier, fast lanes included)
new_gitproj; st set-phase discover; printf '| Dimension | Existing | Decision | Fit | Impact | Effort |\n| x | none | new | 1 | low | S |\n' > "$CLAUDE_PROJECT_DIR/.claude/claudehut/reuse-scan-x.md"
st set-reuse-scan --artifact "$CLAUDE_PROJECT_DIR/.claude/claudehut/reuse-scan-x.md"; st set-complexity small
denies x "{\"session_id\":\"s\",\"tool_input\":{\"file_path\":\"$CLAUDE_PROJECT_DIR/src/main/java/com/x/A.java\"}}" \
  && ok "fast lane: small within bound but skill NOT invoked → deny (skill rail in fast lane)" || bad "fast lane skill rail"
st mark-skill implement
allows x "{\"session_id\":\"s\",\"tool_input\":{\"file_path\":\"$CLAUDE_PROJECT_DIR/src/main/java/com/x/A.java\"}}" \
  && ok "fast lane: small + reuse + within bound + skill → allow (no spec/plan)" || bad "fast lane allow"
# same small tier but touching a security path → DENY (escalate)
denies x "{\"session_id\":\"s\",\"tool_input\":{\"file_path\":\"$CLAUDE_PROJECT_DIR/src/main/java/com/x/SecurityConfig.java\"}}" \
  && ok "fast lane: small touching SecurityConfig → deny (sensitive path)" || bad "fast lane sensitive deny"
rm -rf "$TMP"
# small tier exceeding the file-count bound → DENY
new_gitproj; st set-phase discover; printf '| Dimension | Existing | Decision | Fit | Impact | Effort |\n| x | none | new | 1 | low | S |\n' > "$CLAUDE_PROJECT_DIR/.claude/claudehut/reuse-scan-x.md"
st set-reuse-scan --artifact "$CLAUDE_PROJECT_DIR/.claude/claudehut/reuse-scan-x.md"; st set-complexity small
( cd "$CLAUDE_PROJECT_DIR" && for n in 1 2 3; do echo "class B$n{}" > "src/main/java/com/x/B$n.java"; done )  # 3 untracked
denies x "{\"session_id\":\"s\",\"tool_input\":{\"file_path\":\"$CLAUDE_PROJECT_DIR/src/main/java/com/x/B1.java\"}}" \
  && ok "fast lane: small exceeding file cap → deny (escalate)" || bad "fast lane cap deny"
rm -rf "$TMP"
# full tier (default) still requires spec+plan even with reuse set
new_gitproj; st set-phase discover; printf '| Dimension | Existing | Decision | Fit | Impact | Effort |\n| x | none | new | 1 | low | S |\n' > "$CLAUDE_PROJECT_DIR/.claude/claudehut/reuse-scan-x.md"
st set-reuse-scan --artifact "$CLAUDE_PROJECT_DIR/.claude/claudehut/reuse-scan-x.md"
denies x "{\"session_id\":\"s\",\"tool_input\":{\"file_path\":\"$CLAUDE_PROJECT_DIR/src/main/java/com/x/A.java\"}}" \
  && ok "full tier: reuse only, no spec → still deny" || bad "full tier deny"
rm -rf "$TMP"
# reuse-scan rail enforced in EVERY tier: trivial without reuse → deny
new_gitproj; st set-phase discover; st set-complexity trivial
denies x "{\"session_id\":\"s\",\"tool_input\":{\"file_path\":\"$CLAUDE_PROJECT_DIR/src/main/java/com/x/A.java\"}}" \
  && ok "rail: trivial without reuse-scan → deny (no tier skips the reuse rail)" || bad "trivial reuse rail"
rm -rf "$TMP"

echo "== gate-write: skill rail + recorder (Issue 1) =="
# Qualified skill name (claudehut:implement) opens the rail too
new_proj; st set-phase brainstorm
chd="$CLAUDE_PROJECT_DIR/.claude/claudehut"; mkdir -p "$chd/specs" "$chd/plans"
printf '| Dimension | Existing | Decision | Fit | Impact | Effort |\n| x | none | new | 1 | low | S |\n' > "$chd/reuse-scan-x.md"; st set-reuse-scan --artifact "$chd/reuse-scan-x.md"
printf '## 1. Problem & Context\nx\n## 5. Acceptance Criteria\n- AC-001 GIVEN a WHEN b THEN c\n## 9. Decision Record\nOutcome: A\n' > "$chd/specs/x.md"; st set-spec "$chd/specs/x.md"
printf '## 3. Implementation Flow\nA->B->C\n**T-001 sketch**: foo() control-flow\n## 4. Task Breakdown\n| ID | Goal |\n| T-001 | x |\n' > "$chd/plans/x.md"; st set-plan "$chd/plans/x.md"
st mark-skill claudehut:implement
allows x "$PROD" && ok "skill rail: qualified name claudehut:implement accepted" || bad "skill rail: qualified name"
# Unrelated skill is a no-op (rail stays open)
st mark-skill review
allows x "$PROD" && ok "skill rail: unrelated skill no-op (rail stays open)" || bad "skill rail: unrelated skill"
# New-task boundary resets the rail: set-phase discover → deny again
st set-phase discover
denies x "$PROD" && ok "skill rail: set-phase discover resets (per-TASK invocation required)" || bad "skill rail: discover reset"
# Skill(discover) via recorder also resets (task started through the skill, not set-phase)
st set-bypass true; st set-phase implement; st set-bypass false; st mark-skill implement
allows x "$PROD" && ok "skill rail: re-armed via mark-skill implement" || bad "skill rail: re-arm"
st mark-skill discover
denies x "$PROD" && ok "skill rail: mark-skill discover resets (new task via Skill tool)" || bad "skill rail: skill-discover reset"
rm -rf "$TMP"
# record-skill.sh end-to-end: real PreToolUse(Skill) payload sets the flag through claudehut-state
new_proj; st set-phase brainstorm
echo '{"session_id":"s","tool_name":"Skill","tool_input":{"skill":"claudehut:implement"}}' | "$ROOT/scripts/record-skill.sh" >/dev/null 2>&1
jq -e '.implement_skill_ok==true' "$CLAUDE_PROJECT_DIR/.claude/claudehut/state/s.json" >/dev/null 2>&1 \
  && ok "record-skill.sh: PreToolUse(Skill) payload → implement_skill_ok=true" || bad "record-skill.sh: flag not set"
echo '{"session_id":"s","tool_name":"Skill","tool_input":{"skill":"discover"}}' | "$ROOT/scripts/record-skill.sh" >/dev/null 2>&1
jq -e '.implement_skill_ok==false' "$CLAUDE_PROJECT_DIR/.claude/claudehut/state/s.json" >/dev/null 2>&1 \
  && ok "record-skill.sh: Skill(discover) payload → rail reset" || bad "record-skill.sh: reset not applied"
rm -rf "$TMP"
# Migration: PRE-v0.4 state file (no implement_skill_ok field at all) → rail closed → deny
# (one-deny upgrade cost; the deny message names the recovery: invoke claudehut:implement)
new_proj
chd="$CLAUDE_PROJECT_DIR/.claude/claudehut"; mkdir -p "$chd/specs" "$chd/plans"
printf '| Dimension | Existing | Decision | Fit | Impact | Effort |\n| x | none | new | 1 | low | S |\n' > "$chd/reuse-scan-x.md"
printf '## 1. Problem & Context\nx\n## 5. Acceptance Criteria\n- AC-001 GIVEN a WHEN b THEN c\n## 9. Decision Record\nOutcome: A\n' > "$chd/specs/x.md"
printf '## 3. Implementation Flow\nA->B->C\n**T-001 sketch**: foo() control-flow\n## 4. Task Breakdown\n| ID | Goal |\n| T-001 | x |\n' > "$chd/plans/x.md"
jq -n '{session:"s",phase:"implement",reuse_scan:true,reuse_scan_artifact:"'"$chd"'/reuse-scan-x.md",spec_path:"'"$chd"'/specs/x.md",plan_path:"'"$chd"'/plans/x.md",review:"pending",outstanding:[],bypass:false,complexity:"full"}' > "$chd/state/s.json"
denies x "$PROD" && ok "migration: pre-v0.4 state (field absent) → rail closed, deny with recovery hint" || bad "migration: legacy state not gated"
st mark-skill implement
allows x "$PROD" && ok "migration: one mark-skill re-opens a legacy-state session" || bad "migration: legacy state not recoverable"
rm -rf "$TMP"
# Unrelated skill must not OPEN a closed rail either
new_proj; st set-phase brainstorm
chd="$CLAUDE_PROJECT_DIR/.claude/claudehut"; mkdir -p "$chd/specs" "$chd/plans"
printf '| Dimension | Existing | Decision | Fit | Impact | Effort |\n| x | none | new | 1 | low | S |\n' > "$chd/reuse-scan-x.md"; st set-reuse-scan --artifact "$chd/reuse-scan-x.md"
printf '## 1. Problem & Context\nx\n## 5. Acceptance Criteria\n- AC-001 GIVEN a WHEN b THEN c\n## 9. Decision Record\nOutcome: A\n' > "$chd/specs/x.md"; st set-spec "$chd/specs/x.md"
printf '## 3. Implementation Flow\nA->B->C\n**T-001 sketch**: foo() control-flow\n## 4. Task Breakdown\n| ID | Goal |\n| T-001 | x |\n' > "$chd/plans/x.md"; st set-plan "$chd/plans/x.md"
st mark-skill review
denies x "$PROD" && ok "skill rail: unrelated skill does NOT open a closed rail" || bad "skill rail: unrelated skill opened rail"
rm -rf "$TMP"
# bootstrap restore: live state missing + snapshot present → snapshot restored (skill rail survives)
new_proj; st set-phase brainstorm; st mark-skill implement
cp "$CLAUDE_PROJECT_DIR/.claude/claudehut/state/s.json" "$CLAUDE_PROJECT_DIR/.claude/claudehut/state/s.snapshot.json"
rm "$CLAUDE_PROJECT_DIR/.claude/claudehut/state/s.json"
echo '{"session_id":"s"}' | "$ROOT/scripts/bootstrap.sh" >/dev/null 2>&1
jq -e '.implement_skill_ok==true' "$CLAUDE_PROJECT_DIR/.claude/claudehut/state/s.json" >/dev/null 2>&1 \
  && ok "bootstrap: snapshot restored when live state missing (rail survives)" || bad "bootstrap: snapshot restore"
rm -rf "$TMP"

echo "== verify-subagent =="
new_proj
echo '{"agent_type":"claudehut-reuse-scanner"}' | "$ROOT/scripts/verify-subagent.sh" | jq -e '.decision=="block"' >/dev/null 2>&1 && ok "block: reuse-scanner, no artifact" || bad "block: scanner"
touch "$CLAUDE_PROJECT_DIR/.claude/claudehut/reuse-scan-x.md"
[ -z "$(echo '{"agent_type":"claudehut-reuse-scanner"}' | "$ROOT/scripts/verify-subagent.sh")" ] && ok "allow: reuse-scanner with artifact" || bad "allow: scanner artifact"
[ -z "$(echo '{"agent_type":"claudehut-reviewer"}' | "$ROOT/scripts/verify-subagent.sh")" ] && ok "allow: text agent (reviewer)" || bad "allow: text agent"
# HANG-FIX cap: at stop_hook_active the hook must fail OPEN even with the artifact missing —
# otherwise a mispathed artifact = infinite SubagentStop block loop (presents as a hang).
rm -rf "$TMP"; new_proj
[ -z "$(echo '{"agent_type":"claudehut-planner","stop_hook_active":true}' | "$ROOT/scripts/verify-subagent.sh")" ] \
  && ok "cap: stop_hook_active fails open (no infinite block / hang)" || bad "cap: stop_hook_active still blocks"
echo '{"agent_type":"claudehut-planner","stop_hook_active":false}' | "$ROOT/scripts/verify-subagent.sh" | jq -e '.decision=="block"' >/dev/null 2>&1 \
  && ok "block: planner, no artifact, below cap" || bad "block: planner below cap"
rm -rf "$TMP"

echo "== gate-write: MultiEdit (P1-2) =="
new_proj; st set-phase brainstorm
chd="$CLAUDE_PROJECT_DIR/.claude/claudehut"; mkdir -p "$chd"
# MultiEdit on test files only -> all paths exempt -> allow (even without reuse scan)
allows x '{"session_id":"s","tool_name":"MultiEdit","tool_input":{"file_edits":[{"file_path":"/p/src/test/java/FooTest.java","changes":[]},{"file_path":"/p/src/test/java/BarTest.java","changes":[]}]}}' \
  && ok "P1-2: MultiEdit test-only files exempt (allowed)" || bad "P1-2: MultiEdit test files wrongly gated"
# MultiEdit on .claude/claudehut artifacts only -> all exempt -> allow
allows x '{"session_id":"s","tool_name":"MultiEdit","tool_input":{"file_edits":[{"file_path":"/p/.claude/claudehut/tasks/0001-slug/spec.md","changes":[]}]}}' \
  && ok "P1-2: MultiEdit artifact path exempt" || bad "P1-2: MultiEdit artifact path wrongly gated"
# MultiEdit mixing prod + test -> not all paths exempt -> gates on reuse_scan
denies x '{"session_id":"s","tool_name":"MultiEdit","tool_input":{"file_edits":[{"file_path":"/p/src/main/java/Foo.java","changes":[]},{"file_path":"/p/src/test/java/FooTest.java","changes":[]}]}}' \
  && ok "P1-2: MultiEdit mixed prod+test correctly gated (reuse_scan missing)" || bad "P1-2: MultiEdit mixed not gated"
# Real CC MultiEdit payload uses a SINGLE top-level file_path (many edits to one file), NOT file_edits[].
# These cover the shape production actually sends (the file_edits[] fixtures above are legacy/defensive).
denies x '{"session_id":"s","tool_name":"MultiEdit","tool_input":{"file_path":"/p/src/main/java/Foo.java","edits":[{"old_string":"a","new_string":"b"}]}}' \
  && ok "P1-2: MultiEdit real shape (top-level file_path) prod file gated" || bad "P1-2: MultiEdit top-level file_path NOT gated (gate bypass)"
allows x '{"session_id":"s","tool_name":"MultiEdit","tool_input":{"file_path":"/p/src/test/java/FooTest.java","edits":[{"old_string":"a","new_string":"b"}]}}' \
  && ok "P1-2: MultiEdit real shape test file exempt" || bad "P1-2: MultiEdit real-shape test file wrongly gated"
rm -rf "$TMP"

echo "== claudehut-state: set-review pass earned-evidence (review-rigor v0.5) =="
new_proj; st set-phase review
# pass with no --evidence → rejected
"$ROOT/bin/claudehut-state" --session s set-review pass >/dev/null 2>&1 \
  && bad "set-review pass without --evidence accepted" || ok "reject: set-review pass needs --evidence"
# pass with --evidence to a missing file → rejected
"$ROOT/bin/claudehut-state" --session s set-review pass --evidence "$CLAUDE_PROJECT_DIR/.claude/claudehut/tasks/0001-x/review.md" >/dev/null 2>&1 \
  && bad "set-review pass accepted a missing evidence file" || ok "reject: evidence file must exist"
# evidence with no coverage table → rejected
ev="$CLAUDE_PROJECT_DIR/.claude/claudehut/tasks/0001-x/review.md"; mkdir -p "$(dirname "$ev")"
printf '# Review\nlooks good, shipping.\n' > "$ev"
"$ROOT/bin/claudehut-state" --session s set-review pass --evidence "$ev" >/dev/null 2>&1 \
  && bad "set-review pass accepted evidence with no coverage table" || ok "reject: evidence needs a coverage table (✓/✗/n-a rows)"
# coverage table but no test evidence → rejected
printf '# Review\n| Item | Status | Evidence |\n|---|---|---|\n| x | ✓ satisfied | A.java:1 |\n' > "$ev"
"$ROOT/bin/claudehut-state" --session s set-review pass --evidence "$ev" >/dev/null 2>&1 \
  && bad "set-review pass accepted evidence with no test summary" || ok "reject: evidence needs fresh test evidence"
# prose that merely contains the words "satisfied"/"passing" but has NO table row → rejected (bypass guard)
printf '# Review\nAll requirements are satisfied. Tests are passing. Shipping.\n' > "$ev"
"$ROOT/bin/claudehut-state" --session s set-review pass --evidence "$ev" >/dev/null 2>&1 \
  && bad "set-review pass accepted prose with keywords but no table row" || ok "reject: prose with 'satisfied/passing' but no '|' table row"
# non-canonical evidence path → rejected
printf '| x | ✓ | A.java:1 |\n./gradlew test 5 passed\n' > /tmp/ch-bad-review.md
"$ROOT/bin/claudehut-state" --session s set-review pass --evidence /tmp/ch-bad-review.md >/dev/null 2>&1 \
  && bad "set-review pass accepted non-canonical evidence path" || ok "reject: evidence must be under .claude/claudehut/"
rm -f /tmp/ch-bad-review.md
# full valid evidence → accepted, review=pass + review_evidence recorded
review_pass && jq -e '.review=="pass" and (.review_evidence|type=="string")' "$CLAUDE_PROJECT_DIR/.claude/claudehut/state/s.json" >/dev/null 2>&1 \
  && ok "allow: set-review pass with valid coverage-table + test evidence" || bad "valid evidence rejected"
# pending/capped need no evidence
"$ROOT/bin/claudehut-state" --session s set-review pending >/dev/null 2>&1 && ok "set-review pending needs no evidence" || bad "pending wrongly required evidence"
rm -rf "$TMP"

echo "== gate-done: learn gate via per-session receipt (WS-6) =="
# phase=learn but NO learn-receipt -> block (hollow learn: capture-learnings/merge did not run this task)
new_proj; st set-profile feature; st set-phase implement; review_pass
st set-phase learn
blocks x '{"session_id":"s","stop_hook_active":false}' \
  && ok "WS-6: phase=learn + NO learn-receipt -> blocked (hollow learn)" || bad "WS-6: hollow learn not blocked"
# Fresh receipt -> allow
mk_receipt
done_ok x '{"session_id":"s","stop_hook_active":false}' \
  && ok "WS-6: phase=learn + fresh learn-receipt -> allowed" || bad "WS-6: valid learn blocked"
# STALE receipt (older than THIS task's reuse-scan) -> block (Learn ran for a prior task, not this one)
mkdir -p "$CLAUDE_PROJECT_DIR/.claude/claudehut/tasks/0001-x"
RS="$CLAUDE_PROJECT_DIR/.claude/claudehut/tasks/0001-x/reuse-scan.md"
printf '| Dimension | Existing | Decision | Fit | Impact | Effort |\n| x | none | new | 1 | low | S |\n' > "$RS"
st set-reuse-scan --artifact .claude/claudehut/tasks/0001-x/reuse-scan.md
touch "$CLAUDE_PROJECT_DIR/.claude/claudehut/state/s.learn-receipt.json"; sleep 1; touch "$RS"
blocks x '{"session_id":"s","stop_hook_active":false}' \
  && ok "WS-6: stale receipt (older than this task's reuse-scan) -> blocked" || bad "WS-6: stale receipt not blocked"
# Re-run learn (fresh receipt) -> allow again
mk_receipt
done_ok x '{"session_id":"s","stop_hook_active":false}' \
  && ok "WS-6: re-run learn (fresh receipt newer than reuse-scan) -> allowed" || bad "WS-6: fresh re-learn blocked"
rm -rf "$TMP"

echo "== verify-subagent: learner mtime (P1-1 defense-in-depth) =="
new_proj
# No state file -> fail open (no block)
[ -z "$(echo '{"session_id":"s","agent_type":"claudehut-learner","stop_hook_active":false}' | "$ROOT/scripts/verify-subagent.sh")" ] \
  && ok "P1-1 verify: learner, no state file -> fail open" || bad "P1-1 verify: fail open broken"
# Create state file, then a learn-candidates.jsonl older than state file -> block (learner's new contract:
# it writes candidates; merge-learnings.sh writes learnings.jsonl afterward)
mkdir -p "$CLAUDE_PROJECT_DIR/.claude/claudehut/state" "$CLAUDE_PROJECT_DIR/.claude/claudehut/tasks/0001-x"
touch "$CLAUDE_PROJECT_DIR/.claude/claudehut/tasks/0001-x/learn-candidates.jsonl"
sleep 1
echo '{}' > "$CLAUDE_PROJECT_DIR/.claude/claudehut/state/s.json"
echo '{"session_id":"s","agent_type":"claudehut-learner","stop_hook_active":false}' | "$ROOT/scripts/verify-subagent.sh" | jq -e '.decision=="block"' >/dev/null 2>&1 \
  && ok "P1-1 verify: learner, candidates older than state -> block" || bad "P1-1 verify: stale candidates not blocked"
# Touch candidates to make it newer -> allow
touch "$CLAUDE_PROJECT_DIR/.claude/claudehut/tasks/0001-x/learn-candidates.jsonl"
[ -z "$(echo '{"session_id":"s","agent_type":"claudehut-learner","stop_hook_active":false}' | "$ROOT/scripts/verify-subagent.sh")" ] \
  && ok "P1-1 verify: learner, candidates newer than state -> allow" || bad "P1-1 verify: fresh candidates still blocked"
# stop_hook_active cap -> fail open regardless
[ -z "$(echo '{"session_id":"s","agent_type":"claudehut-learner","stop_hook_active":true}' | "$ROOT/scripts/verify-subagent.sh")" ] \
  && ok "P1-1 verify: stop_hook_active cap -> fail open" || bad "P1-1 verify: cap not respected"
rm -rf "$TMP"

echo "== claudehut-state: phase transition guard (P2-2) =="
new_proj; st set-phase brainstorm
# Forward: brainstorm -> spec -> ok
st set-phase spec && ok "P2-2: forward brainstorm->spec allowed" || bad "P2-2: forward blocked"
# Forward: spec -> plan -> ok
st set-phase plan && ok "P2-2: forward spec->plan allowed" || bad "P2-2: forward blocked"
# Backward: plan -> spec -> REJECTED
"$ROOT/bin/claudehut-state" --session s set-phase spec >/dev/null 2>&1 \
  && bad "P2-2: backward plan->spec was allowed (guard missing)" || ok "P2-2: backward plan->spec rejected"
# Backward: plan -> discover -> ALLOWED (discover is always a valid restart)
st set-phase discover && ok "P2-2: discover always valid restart" || bad "P2-2: discover restart blocked"
# bypass=true allows backward jump
st set-profile feature; st set-phase implement; st set-bypass true
st set-phase brainstorm && ok "P2-2: bypass=true allows backward" || bad "P2-2: bypass=true blocked"
# Tier skip path: discover -> implement (skipping middle phases) -> ALLOWED (forward)
new_proj; st set-profile feature; st set-phase discover
st set-phase implement && ok "P2-2: tier-skip discover->implement allowed (forward)" || bad "P2-2: tier-skip blocked"
rm -rf "$TMP"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
