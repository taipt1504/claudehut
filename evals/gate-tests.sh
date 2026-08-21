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
# Engagement at phase=discover requires a RECORDED reuse-scan, and set-reuse-scan content-gates the
# artifact (Fit/Impact columns + a decision token). Writing state.json by hand would bypass the gate the
# rest of the suite exists to exercise, so this goes through the real verb.
reuse_scan_done() {
  local a="$CLAUDE_PROJECT_DIR/.claude/claudehut/tasks/0001-x/reuse-scan.md"
  mkdir -p "$(dirname "$a")"
  printf '# Reuse scan\n| Dimension | Existing asset | Decision | Fit | Impact | Effort |\n|---|---|---|---|---|---|\n| http client | RestClientConfig | extend | high | med | S |\n' > "$a"
  "$ROOT/bin/claudehut-state" --session s set-reuse-scan --artifact "$a" >/dev/null
}
denies()  { echo "$2" | "$ROOT/scripts/gate-write.sh" | jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null 2>&1; }
allows()  { [ -z "$(echo "$2" | "$ROOT/scripts/gate-write.sh")" ]; }
blocks()  { echo "$2" | "$ROOT/scripts/gate-done.sh" | jq -e '.decision=="block"' >/dev/null 2>&1; }
# IDEA-F10: the pass path may now emit a non-blocking advisory systemMessage. "Passed" means "did not
# BLOCK", not "printed nothing" — asserting empty stdout would forbid any future advisory, which is a
# shape constraint rather than a behavioural one. 11 call sites depend on this helper.
done_ok() { ! echo "$2" | "$ROOT/scripts/gate-done.sh" | jq -e '.decision=="block"' >/dev/null 2>&1; }

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
st set-bypass true --reason "eval fixture"; allows x "$PROD" && ok "allow: bypass=true" || bad "allow: bypass"
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
# tier-aware completion (Issue 4 × gate-done interaction — trivial skips Learn, must NOT wedge)
new_proj; st set-phase review; review_pass; st set-complexity trivial
done_ok x '{"session_id":"s","stop_hook_active":false}' && ok "allow: trivial tier — review=pass terminates WITHOUT Learn (no wedge)" || bad "trivial done without learn"
st set-complexity small
blocks x '{"session_id":"s","stop_hook_active":false}' && ok "block: small tier still requires Learn" || bad "small learn required"
rm -rf "$TMP"

# ── gate-done: the block REASON must name the next action, not the last gate ────────────────────────
# Reported from a live session: the Stop hook fired "Review not passed — run claudehut:review" while the
# task was nowhere near Review. One sentence was emitted at every phase, so the gate that exists to stop
# the workflow being skipped was itself ordering a 2-4 phase skip — and it named an exit condition
# ("until the outstanding set is empty") that is ALREADY TRUE for the whole run-up to Review.
echo "== gate-done: the block reason is phase-aware (live-session report) =="
reason() { echo '{"session_id":"s","stop_hook_active":false}' | "$ROOT/scripts/gate-done.sh" 2>/dev/null | jq -r '.reason // ""'; }

new_proj; st set-profile feature; reuse_scan_done
# The defect case. Engaged at discover on a full-tier task: the next phase is Brainstorm.
R="$(reason)"
case "$R" in *"claudehut:brainstorm"*) ok "gate-done: at phase=discover the reason names Brainstorm, the actual next phase" ;;
  *) bad "gate-done: at phase=discover the reason does not name Brainstorm — got: ${R:0:110}" ;; esac
case "$R" in *"run claudehut:review"*|*"Next: claudehut:review"*)
      bad "gate-done: at phase=discover the reason still orders a jump to Review (skips Brainstorm/Spec/Plan)" ;;
  *)  ok "gate-done: at phase=discover the reason does NOT order a jump to Review" ;; esac
# CONTROL 1 — a reason that named the next phase for every input would satisfy the assertion above while
# being just as wrong. At implement, Review IS the next phase and must still be named.
st set-phase implement; R="$(reason)"
case "$R" in *"claudehut:review"*) ok "gate-done: control — at phase=implement the reason still names Review" ;;
  *) bad "gate-done: control — at phase=implement the reason failed to name Review: ${R:0:110}" ;; esac
# CONTROL 2 — the tier changes the answer: small/trivial skip Brainstorm/Spec/Plan entirely, so routing a
# small-tier discover to Brainstorm would be the same class of wrong instruction in the other direction.
new_proj; st set-profile feature; reuse_scan_done; st set-complexity small; R="$(reason)"
case "$R" in *"claudehut:implement"*) ok "gate-done: control — small tier at discover routes to Implement, not Brainstorm" ;;
  *) bad "gate-done: control — small tier at discover did not route to Implement: ${R:0:110}" ;; esac
case "$R" in *"claudehut:brainstorm"*) bad "gate-done: small tier sent to Brainstorm, which that tier skips" ;;
  *) ok "gate-done: small tier is not sent to the Brainstorm phase it skips" ;; esac
rm -rf "$TMP"

# review=capped is claudehut:review declaring its 2-round fix loop exhausted. The old reason told it to
# loop again — the round cap and the completion gate contradicting each other. It must still BLOCK
# (set-review capped takes no evidence, so passing here would make the cap a free escape hatch).
new_proj; st set-profile feature; st set-phase implement; st set-review capped
blocks x '{"session_id":"s","stop_hook_active":false}' \
  && ok "gate-done: review=capped still BLOCKS (capped needs no evidence — it must not be an escape hatch)" \
  || bad "gate-done: review=capped satisfied the completion gate — free escape hatch"
R="$(reason)"
case "$R" in *"do NOT dispatch another review round"*) ok "gate-done: review=capped is told to surface the survivors, not to re-loop" ;;
  *) bad "gate-done: review=capped is still told to run review again, against the cap: ${R:0:110}" ;; esac
rm -rf "$TMP"

# The completion gate must not write to stderr: Claude Code renders any stderr from a Stop hook to the
# user as "Stop hook error". `find | grep -c .` printed "0" and exited 1, so the `|| echo 0` fallback
# appended a second 0 and the -gt comparison died with "integer expression expected" on every clean pass.
new_proj; st set-profile feature; st set-phase review; review_pass; mk_receipt; st set-phase learn
ERRF="$TMP/stop.err"
echo '{"session_id":"s","stop_hook_active":false}' | "$ROOT/scripts/gate-done.sh" >/dev/null 2>"$ERRF"
[ ! -s "$ERRF" ] && ok "gate-done: the clean pass writes nothing to stderr (no phantom 'Stop hook error')" \
  || bad "gate-done: stderr on a clean pass — $(head -c 90 "$ERRF")"
# CONTROL — the advisory it guards still fires when sidecars really are stale, so the fix is not a mute.
touch -t 202501010000 "$CLAUDE_PROJECT_DIR/.claude/claudehut/state/x.failures.jsonl"
ADVS="$(echo '{"session_id":"s","stop_hook_active":false}' | "$ROOT/scripts/gate-done.sh" 2>/dev/null | jq -r '.systemMessage // ""')"
case "$ADVS" in *"older than 7 days"*) ok "gate-done: control — the stale-sidecar advisory still fires when files ARE stale" ;;
  *) bad "gate-done: the stale-sidecar advisory was silenced rather than fixed: ${ADVS:0:90}" ;; esac
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
st set-bypass true --reason "eval fixture"; st set-phase implement; st set-bypass false; st mark-skill implement
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

# PRODUCTION PAYLOAD SHAPE. Every assertion above feeds the BARE frontmatter name, but the runtime delivers the
# plugin-scoped identifier for plugin-shipped subagents ("claudehut:claudehut-planner" —
# https://code.claude.com/docs/en/hooks). Those tests therefore passed for years against a code path that never
# executed in production: the case arms matched bare names only, so every real dispatch fell through to *).
# These assertions pin the REAL shape, so a regression of the prefix-strip is caught.
new_proj
echo '{"agent_type":"claudehut:claudehut-reuse-scanner"}' | "$ROOT/scripts/verify-subagent.sh" | jq -e '.decision=="block"' >/dev/null 2>&1 \
  && ok "scoped: plugin-scoped reuse-scanner is enforced (not a no-op)" || bad "scoped: reuse-scanner falls through"
echo '{"agent_type":"claudehut:claudehut-planner","stop_hook_active":false}' | "$ROOT/scripts/verify-subagent.sh" | jq -e '.decision=="block"' >/dev/null 2>&1 \
  && ok "scoped: plugin-scoped planner is enforced (not a no-op)" || bad "scoped: planner falls through"
[ -z "$(echo '{"agent_type":"claudehut:claudehut-reviewer"}' | "$ROOT/scripts/verify-subagent.sh")" ] \
  && ok "scoped: plugin-scoped text agent still exempt (no false block)" || bad "scoped: text agent falsely blocked"
[ -z "$(echo '{"agent_type":"claudehut:claudehut-planner","stop_hook_active":true}' | "$ROOT/scripts/verify-subagent.sh")" ] \
  && ok "scoped: stop_hook_active cap still fails open" || bad "scoped: cap broken"
rm -rf "$TMP"

# F5 (v0.12) — the dispatch ledger. Every payload below is the REAL key set, probed on Claude Code 2.1.234:
# SubagentStart carries agent_id/agent_type/cwd/hook_event_name/prompt_id/session_id/transcript_path and
# NOT effort; SubagentStop adds effort (an object) and agent_transcript_path. The four `[ -z "$(…)" ]`
# assertions above are the stdout-purity guard for the stop-half append — verify-subagent.sh is a BLOCKING
# hook, so a single stray byte on its stdout would read as a false block.
echo "== F5: dispatch ledger (start + stop, joined on agent_id) =="
new_proj
LED="$CLAUDE_PROJECT_DIR/.claude/claudehut/ledger/dispatches.jsonl"
echo '{"session_id":"s","agent_id":"agent_abc123","agent_type":"claudehut:claudehut-reviewer","cwd":"/some/worktree","hook_event_name":"SubagentStart","prompt_id":"p1","transcript_path":"/t.jsonl"}' \
  | "$ROOT/scripts/record-dispatch.sh" >/dev/null 2>&1
[ -f "$LED" ] && ok "F5: ledger is at .claude/claudehut/ledger/dispatches.jsonl (out of the age-swept state/ dir)" \
  || bad "F5: no ledger at ledger/dispatches.jsonl"
[ ! -f "$CLAUDE_PROJECT_DIR/.claude/claudehut/state/s.dispatches.jsonl" ] \
  && ok "F5: nothing is written to the old state/<sid>.dispatches.jsonl path" || bad "F5: still writing the swept path"
# VALUES, not keys — `has("agent_id")` passes on a record whose agent_id is "", which is the hollow-record
# class (682 of them in v0.11) this whole item exists to avoid.
jq -e '.agent_id=="agent_abc123" and .event=="start" and .session_id=="s" and .cwd=="/some/worktree"' "$LED" >/dev/null 2>&1 \
  && ok "F5: start record carries a NON-EMPTY agent_id, plus session_id and cwd" || bad "F5: start record hollow or missing fields"
# effort is measured ABSENT on SubagentStart. Writing the key anyway would be a field matching nothing.
jq -e 'has("effort")|not' "$LED" >/dev/null 2>&1 \
  && ok "F5: start record writes no effort field (SubagentStart does not carry one)" || bad "F5: start record invents an effort field"
# stop half — appended by the blocking SubagentStop hook
echo '{"session_id":"s","agent_id":"agent_abc123","agent_type":"claudehut:claudehut-reviewer","effort":{"level":"xhigh"},"agent_transcript_path":"/p/subagents/agent-agent_abc123.jsonl","stop_hook_active":false,"hook_event_name":"SubagentStop"}' \
  | "$ROOT/scripts/verify-subagent.sh" >/dev/null 2>&1
jq -e 'select(.event=="stop") | .agent_id=="agent_abc123" and .effort=="xhigh" and (.agent_transcript_path|test("agent-agent_abc123"))' "$LED" >/dev/null 2>&1 \
  && ok "F5: stop record carries agent_id, effort.level unwrapped, and agent_transcript_path" || bad "F5: stop record missing agent_id/effort/transcript"
# THE JOIN is the feature. Without a matching pair there is no wall duration and F5 bought nothing.
jq -s 'group_by(.agent_id)|map(select(.[0].agent_id=="agent_abc123"))|.[0]|(length==2) and ((map(.event)|sort)==["start","stop"])' "$LED" 2>/dev/null | grep -qx true \
  && ok "F5: start and stop pair on agent_id — exactly one of each (wall duration derivable)" || bad "F5: start/stop do not join on agent_id"
# .effort SHAPE. Measured as an object; a bare `.effort.level` against a string value throws, and jq would
# then emit NO record at all — a shape change would silently empty the ledger rather than blank one field.
echo '{"session_id":"s","agent_id":"agent_str","agent_type":"x","effort":"high","stop_hook_active":false}' \
  | "$ROOT/scripts/verify-subagent.sh" >/dev/null 2>&1
jq -e 'select(.agent_id=="agent_str") | .effort=="high"' "$LED" >/dev/null 2>&1 \
  && ok "F5: a STRING effort still yields a record (type switch, not a throwing .effort.level)" || bad "F5: string-shaped effort loses the whole record"
rm -rf "$TMP"
# The append must not disturb the gate it shares a script with: a blocking stop still blocks, and is still
# recorded (the append sits above the contract switch, below the stop_hook_active cap).
new_proj
LED="$CLAUDE_PROJECT_DIR/.claude/claudehut/ledger/dispatches.jsonl"
echo '{"session_id":"s","agent_id":"agent_blk","agent_type":"claudehut:claudehut-reuse-scanner","effort":{"level":"low"},"stop_hook_active":false}' \
  | "$ROOT/scripts/verify-subagent.sh" | jq -e '.decision=="block"' >/dev/null 2>&1 \
  && ok "F5: the ledger append leaves the block decision intact" || bad "F5: ledger append broke the blocking gate"
jq -e 'select(.agent_id=="agent_blk") | .event=="stop"' "$LED" >/dev/null 2>&1 \
  && ok "F5: a BLOCKED stop is still recorded (the ledger sees enforcement, not just happy paths)" || bad "F5: blocked stop went unrecorded"
# ...and a re-entrant stop (the hang cap) must NOT append a second stop for the same dispatch.
echo '{"session_id":"s","agent_id":"agent_blk","agent_type":"claudehut:claudehut-reuse-scanner","stop_hook_active":true}' \
  | "$ROOT/scripts/verify-subagent.sh" >/dev/null 2>&1
[ "$(grep -c 'agent_blk' "$LED")" = "1" ] \
  && ok "F5: stop_hook_active re-entry adds no duplicate stop record (pairing survives a block loop)" || bad "F5: block loop duplicates stop records"
rm -rf "$TMP"

echo "== W20/W21: persist-state (PreCompact) =="
new_proj; st set-phase brainstorm
SNAP="$CLAUDE_PROJECT_DIR/.claude/claudehut/state/s.snapshot.json"
DBG="$CLAUDE_PROJECT_DIR/.claude/claudehut/state/payload-debug.PreCompact.jsonl"
# PRODUCTION PAYLOAD SHAPE. W21 measured this on a real manual compaction (Claude Code 2.1.234): the complete
# PreCompact key set is custom_instructions, cwd, hook_event_name, prompt_id, session_id, transcript_path,
# trigger. Feeding the real shape is what makes the .session_id read falsifiable — a fixture carrying only
# the field the script happens to want proves nothing about production.
PRECOMPACT='{"custom_instructions":"","cwd":"/tmp/x","hook_event_name":"PreCompact","prompt_id":"pr_1","session_id":"s","transcript_path":"/t.jsonl","trigger":"manual"}'
printf '%s' "$PRECOMPACT" | "$ROOT/scripts/persist-state.sh" >/dev/null 2>&1
[ -f "$SNAP" ] && ok "W20: the REAL PreCompact payload snapshots the live state file (the crash-path source)" || bad "W20: snapshot no longer written"
[ ! -f "$DBG" ] && ok "W21: payload capture is OFF by default" || bad "W21: payload written without the flag"
# The capture block is what turned .session_id from a guess into a measurement, and it stays wired so the
# next runtime key-set change is readable rather than silent — an empty sid makes STATE "state/.json", the
# [ -f ] fails, and the hook exits 0 having copied nothing, byte-identical to success.
printf '%s' "$PRECOMPACT" | CLAUDEHUT_DEBUG_PAYLOAD=1 "$ROOT/scripts/persist-state.sh" >/dev/null 2>&1
jq -e '(keys|sort)==["custom_instructions","cwd","hook_event_name","prompt_id","session_id","transcript_path","trigger"]' "$DBG" >/dev/null 2>&1 \
  && ok "W21: CLAUDEHUT_DEBUG_PAYLOAD=1 captures the RAW PreCompact payload verbatim (all 7 measured keys)" || bad "W21: PreCompact payload not captured"
# W20 is a documentation correction, so its assertion is deliberately a documentation assertion: the old
# claim must be GONE, not merely joined by a new one.
grep -q 'Durability before context compaction' "$ROOT/scripts/persist-state.sh" \
  && bad "W20: header still claims compaction durability the hook does not provide" \
  || ok "W20: the overclaiming 'Durability before context compaction' header is gone"
grep -q 'crash insurance whose TRIGGER happens to be a compaction' "$ROOT/scripts/persist-state.sh" \
  && ok "W20: header names the crash path it actually protects" || bad "W20: corrected header missing"
rm -rf "$TMP"

echo "== IDEA-F10: session-hygiene advisory on a clean pass =="
new_proj
mkdir -p "$CLAUDE_PROJECT_DIR/.claude/claudehut/tasks/0001-x"
printf '# reuse scan\n| Dimension | Existing asset | Decision | Fit | Impact | Effort |\n|---|---|---|---|---|---|\n| util | none | build | n/a | low | S |\n' \
  > "$CLAUDE_PROJECT_DIR/.claude/claudehut/tasks/0001-x/reuse-scan.md"
st set-phase discover; st set-complexity small
st set-reuse-scan --artifact "$CLAUDE_PROJECT_DIR/.claude/claudehut/tasks/0001-x/reuse-scan.md"
st mark-skill implement; review_pass; mk_receipt
st set-bypass true --reason "eval fixture"
DONEP='{"session_id":"s"}'
adv="$(printf '%s' "$DONEP" | "$ROOT/scripts/gate-done.sh" | jq -r '.systemMessage // ""')"
printf '%s' "$adv" | grep -q 'bypass ON' \
  && ok "IDEA-F10: a clean pass surfaces the open bypass and its reason" \
  || bad "IDEA-F10: the advisory did not report an open bypass on a passing task"
printf '%s' "$DONEP" | "$ROOT/scripts/gate-done.sh" | jq -e '.decision=="block"' >/dev/null 2>&1 \
  && bad "IDEA-F10: the advisory BLOCKED the Stop path — it must be non-blocking" \
  || ok "IDEA-F10: the advisory never blocks"
st set-bypass false
adv2="$(printf '%s' "$DONEP" | "$ROOT/scripts/gate-done.sh" | jq -r '.systemMessage // ""')"
[ -z "$adv2" ] \
  && ok "IDEA-F10: nothing to report means nothing is said (no per-task noise)" \
  || bad "IDEA-F10: the advisory fires on a clean session with nothing outstanding"

echo "== PLUMB-F-11: the fast-lane bound counts the WHOLE write batch =="
# The bound counted only head -1 of the extracted path list, so a MultiEdit creating five production files
# contributed ONE toward a cap of two — the fast lane passed exactly the change it is sized to reject.
new_proj
( cd "$CLAUDE_PROJECT_DIR" && git init -q 2>/dev/null )
mkdir -p "$CLAUDE_PROJECT_DIR/src/main/java" "$CLAUDE_PROJECT_DIR/.claude/claudehut/tasks/0001-x"
# set-reuse-scan validates the artifact's SHAPE (Fit/Impact columns), so a stub file is rejected and the
# gate then denies for a missing scan rather than for the cap — which is what made the first version of
# this test green with the fix reverted.
printf '# reuse scan\n| Dimension | Existing asset | Decision | Fit | Impact | Effort |\n|---|---|---|---|---|---|\n| util | none | build | n/a | low | S |\n' \
  > "$CLAUDE_PROJECT_DIR/.claude/claudehut/tasks/0001-x/reuse-scan.md"
st set-phase discover
st set-complexity small
st set-reuse-scan --artifact "$CLAUDE_PROJECT_DIR/.claude/claudehut/tasks/0001-x/reuse-scan.md"
st mark-skill implement
_fe() { printf '{"file_path":"%s/src/main/java/%s.java","changes":[]}' "$CLAUDE_PROJECT_DIR" "$1"; }
BATCH5='{"session_id":"s","tool_name":"MultiEdit","tool_input":{"file_edits":['"$(_fe A),$(_fe B),$(_fe C),$(_fe D),$(_fe E)"']}}'
# Assert the REASON, not just the decision: a bare "denies" stayed green with the fix reverted, because the
# fixture was denying for an unrelated reason and the test proved nothing about the cap.
b5reason="$(printf '%s' "$BATCH5" | "$ROOT/scripts/gate-write.sh" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""')"
printf '%s' "$b5reason" | grep -q 'touches 5 files' \
  && ok "PLUMB-F-11: a 5-file MultiEdit is denied BY THE CAP (reason names all 5)" \
  || bad "PLUMB-F-11: denial reason was '$(printf '%s' "$b5reason" | cut -c1-70)' — the cap counted fewer than 5"

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

# EXEMPTION NORMALISATION. The exemption used to match raw substrings (`*"/test/"*`, `*"/.claude/claudehut/"*`),
# so two classes of production write reached ALLOW against an armed gate. Both reproduced before the fix.
echo "== gate-write: exemption is anchored, not substring =="
new_proj; st set-phase brainstorm
denies x '{"session_id":"s","tool_input":{"file_path":"/p/src/main/java/com/acme/test/PaymentService.java"}}' \
  && ok "exempt: production class in a package named 'test' is GATED" || bad "exempt: package 'test' bypasses the gate"
denies x '{"session_id":"s","tool_input":{"file_path":"/p/.claude/claudehut/../../../src/main/java/Evil.java"}}' \
  && ok "exempt: path traversal out of an exempt dir is GATED" || bad "exempt: traversal bypasses the gate"
# The legitimate paths must survive normalisation. These fixtures deliberately have NO *Test.java / *IT.java
# name rescue, so they exercise the test-ROOT arms specifically — with name-matching fixtures the assertions
# stayed green even when the whole test-root arm was deleted.
allows x '{"session_id":"s","tool_input":{"file_path":"/p/src/test/resources/schema.sql"}}' \
  && ok "exempt: src/test resource (no name rescue) allowed" || bad "exempt: test root wrongly gated"
allows x '{"session_id":"s","tool_input":{"file_path":"/p/src/integrationTest/kotlin/com/acme/Pay.kt"}}' \
  && ok "exempt: integrationTest root (no name rescue) allowed" || bad "exempt: integrationTest wrongly gated"
allows x '{"session_id":"s","tool_input":{"file_path":"/p/src/testFixtures/java/com/acme/Builder.java"}}' \
  && ok "exempt: testFixtures root (no name rescue) allowed" || bad "exempt: testFixtures wrongly gated"
allows x '{"session_id":"s","tool_input":{"file_path":"/p/src/commonTest/kotlin/com/acme/Pay.kt"}}' \
  && ok "exempt: kotlin-multiplatform commonTest allowed" || bad "exempt: commonTest wrongly gated"
# tests/ is exempt at the REPO ROOT only, so this fixture must sit under the real project dir. Matching
# absolutely used to mean any ancestor named tests/ exempted the whole checkout.
allows x "{\"session_id\":\"s\",\"tool_input\":{\"file_path\":\"$CLAUDE_PROJECT_DIR/tests/test_payment.py\"}}" \
  && ok "exempt: non-JVM tests/ root allowed" || bad "exempt: tests/ wrongly gated"
denies x '{"session_id":"s","tool_input":{"file_path":"/elsewhere/tests/test_payment.py"}}' \
  && ok "exempt: a tests/ dir OUTSIDE the project does not exempt" || bad "exempt: ancestor tests/ still exempts"
# ...but a production source is never exempt, however it is named or nested
denies x '{"session_id":"s","tool_input":{"file_path":"/p/src/main/java/com/acme/testing/TestDataTest.java"}}' \
  && ok "exempt: src/main wins over every test pattern" || bad "exempt: src/main file slipped through a test pattern"
# Prose is exempt; the exemption must not become an evasion path, and $all_exempt short-circuits BEFORE the
# fast-lane security/migration check, so the gated surfaces are re-asserted here explicitly.
allows x '{"session_id":"s","tool_input":{"file_path":"/p/README.md"}}' \
  && ok "docs: README.md is not gated" || bad "docs: prose write wrongly gated"
allows x '{"session_id":"s","tool_input":{"file_path":"/p/docs/adr/0001-choose-kafka.md"}}' \
  && ok "docs: an ADR is not gated" || bad "docs: ADR wrongly gated"
denies x '{"session_id":"s","tool_input":{"file_path":"/p/src/main/resources/README.md"}}' \
  && ok "docs: a .md inside src/main is still gated" || bad "docs: src/main .md became an evasion path"
# A blanket *.md would disable the gate for any project whose production artifacts ARE markdown - this plugin
# being the obvious one. Only conventional doc locations are exempt.
denies x "{\"session_id\":\"s\",\"tool_input\":{\"file_path\":\"$CLAUDE_PROJECT_DIR/agents/claudehut-reviewer.md\"}}" \
  && ok "docs: a production .md (agents/) is still gated" || bad "docs: blanket .md exemption disables the gate"
denies x "{\"session_id\":\"s\",\"tool_input\":{\"file_path\":\"$CLAUDE_PROJECT_DIR/requirements.txt\"}}" \
  && ok "docs: a .txt build manifest is still gated" || bad "docs: .txt exempted a dependency manifest"
denies x "{\"session_id\":\"s\",\"tool_input\":{\"file_path\":\"$CLAUDE_PROJECT_DIR/.claude/claudehut/state/s.json\"}}" \
  && ok "store: the gate's own state file is NOT exempt (no one-Write bypass)" || bad "store: state file exempt - gate can disable itself"
denies x "{\"session_id\":\"s\",\"tool_input\":{\"file_path\":\"$CLAUDE_PROJECT_DIR/src/com/acme/latest/Pay.java\"}}" \
  && ok "exempt: a 'latest' package does not match the test-root arms" || bad "exempt: substring test-dir match is back"
denies x '{"session_id":"s","tool_input":{"file_path":"/p/db/migration/V2__add_index.sql"}}' \
  && ok "docs: migrations remain gated" || bad "docs: migration slipped through"
allows x '{"session_id":"s","tool_input":{"file_path":"/p/./.claude/claudehut/tasks/0001-x/spec.md"}}' \
  && ok "exempt: artifact path with a '.' segment allowed" || bad "exempt: '.' segment wrongly gated"
rm -rf "$TMP"

echo "== claudehut-state: concurrent writers (lost-update) =="
# bin/claudehut-state is a read-modify-write: it reads the whole state file, patches one field, and writes it
# back. The atomic `mv` protects readers from a torn file but does NOT serialize writers, and hooks
# (record-skill.sh, record-skill-expansion.sh, gate-*.sh) invoke it concurrently with the main thread.
# Measured before the advisory lock: 15/15 lost updates on two orthogonal fields, 11/25 on four.
new_proj
lost=0
for _i in 1 2 3 4 5; do
  rm -f "$CLAUDE_PROJECT_DIR/.claude/claudehut/state/c.json"
  st_c() { CLAUDE_PROJECT_DIR="$CLAUDE_PROJECT_DIR" "$ROOT/bin/claudehut-state" --session c "$@" >/dev/null 2>&1; }
  st_c set-phase discover
  st_c set-complexity small &
  st_c set-profile bugfix &
  st_c set-bypass true --reason "eval fixture" &
  st_c set-outstanding '["x"]' &
  wait
  jq -e '.complexity=="small" and .profile=="bugfix" and .bypass==true and (.outstanding|length)==1' \
    "$CLAUDE_PROJECT_DIR/.claude/claudehut/state/c.json" >/dev/null 2>&1 || lost=$((lost+1))
done
[ "$lost" -eq 0 ] && ok "lock: 4 concurrent writers, 5 trials, zero lost updates" \
  || bad "lock: lost updates in $lost/5 trials (state writer is not serialized)"
[ -z "$(find "$CLAUDE_PROJECT_DIR/.claude/claudehut/state" -name '*.lock' -o -name '*.lock.flock' 2>/dev/null)" ] \
  && ok "lock: released cleanly (no lock files left behind)" || bad "lock: stale lock file left behind"
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
st set-profile feature; st set-phase implement; st set-bypass true --reason "eval fixture"
st set-phase brainstorm && ok "P2-2: bypass=true allows backward" || bad "P2-2: bypass=true blocked"
# Tier skip path: discover -> implement (skipping middle phases) -> ALLOWED (forward)
new_proj; st set-profile feature; st set-phase discover
st set-phase implement && ok "P2-2: tier-skip discover->implement allowed (forward)" || bad "P2-2: tier-skip blocked"
rm -rf "$TMP"

# ── gate-done: audit/investigation profile rail (v0.9 Rec 4 / audit EVAL-2) ──────────────────────────────
# The profile-aware completion path (a findings deliverable instead of a code review) was exercised only in
# conformance.sh; these are the dedicated gate-unit cases. NB: the park-and-wait fail-open is NOT covered here
# — that code lives on the separate stop-gate PR branch, not on this one.
echo "== gate-done: audit/investigation profile rail (WS-7 × v0.9 Rec 4) =="
mk_findings() { local p="$CLAUDE_PROJECT_DIR/.claude/claudehut/tasks/$1/findings.md"; mkdir -p "$(dirname "$p")"; printf '# Findings\n- Foo.java:%s — issue\n' "$2" > "$p"; echo "$p"; }
# 1) declaring profile=audit IS engagement — the gate arms (blocks for a findings deliverable), not skipped as non-engaged
new_proj; st set-profile audit
blocks x '{"session_id":"s","stop_hook_active":false}' \
  && ok "profile rail: audit declared IS engagement + no findings → blocked" || bad "profile rail: audit not engaged / not blocked"
# 2) audit + RECORDED findings but no learn-receipt on a non-trivial tier → still blocked
f="$(mk_findings 0001-x 10)"; st set-findings "$f"; st set-complexity full
blocks x '{"session_id":"s","stop_hook_active":false}' \
  && ok "profile rail: audit + findings, no learn-receipt (non-trivial) → blocked" || bad "profile rail: audit skipped the learn-receipt"
# 3) audit + findings + learn-receipt → done ALLOWED (findings rail, not code review)
mk_receipt
done_ok x '{"session_id":"s","stop_hook_active":false}' \
  && ok "profile rail: audit + recorded findings + learn-receipt → done (no code review required)" || bad "profile rail: audit blocked despite deliverable + receipt"
rm -rf "$TMP"
# 4) trivial audit legitimately skips the learn-receipt
new_proj; st set-profile audit; st set-complexity trivial
f="$(mk_findings 0002-y 3)"; st set-findings "$f"
done_ok x '{"session_id":"s","stop_hook_active":false}' \
  && ok "profile rail: trivial audit + findings → done WITHOUT learn-receipt (tier skip)" || bad "profile rail: trivial audit wrongly required a receipt"
rm -rf "$TMP"
# 5) investigation behaves like audit (findings deliverable, not code review)
new_proj; st set-profile investigation; st set-complexity full
f="$(mk_findings 0003-z 7)"; st set-findings "$f"; mk_receipt
done_ok x '{"session_id":"s","stop_hook_active":false}' \
  && ok "profile rail: investigation + findings + receipt → done allowed" || bad "profile rail: investigation blocked despite deliverable"
rm -rf "$TMP"

# ── set-plan sensitive predicate: the keyword set write-plan now mirrors ─────────────────────────────────
# write-plan dispatches the plan-reviewer on set-plan's OWN predicate (≥5 T-rows OR a sensitive keyword)
# instead of on every plan, so that keyword set is load-bearing prose in the skill. Only `security`/`auth`
# were ever exercised; the other eight keywords could have been narrowed without a red test, which would
# make the skill's mirrored list wrong — the model skips the dispatch and set-plan then refuses the plan.
echo "== set-plan sensitive predicate (the list write-plan mirrors) =="
new_proj; st set-profile feature; st set-complexity full
PDT="$CLAUDE_PROJECT_DIR/.claude/claudehut/tasks/0007-liq"; mkdir -p "$PDT"
# 4 tasks — under the ≥5 substantial threshold, so `liquibase` is the ONLY thing that can arm the gate.
printf '%s\n' '# P' '## Implementation Flow' 'changelog applied at boot' '**T-001 sketch**: liquibase changeSet' \
  '| T-001 | db/changelog.xml | tf | v | - |' '| T-002 | a | tf | v | - |' \
  '| T-003 | b | tf | v | - |' '| T-004 | c | tf | v | - |' > "$PDT/plan.md"
"$ROOT/bin/claudehut-state" --session s set-plan .claude/claudehut/tasks/0007-liq/plan.md >/dev/null 2>&1 \
  && bad "sensitive predicate: 4-task liquibase plan ACCEPTED with no plan-reviewer APPROVE (keyword dropped)" \
  || ok "sensitive predicate: 4-task liquibase plan REQUIRES a plan-reviewer APPROVE (non-security keyword arms the gate)"
printf '%s\n' '| Check | Status | Evidence |' '| AC-001 covered | ✓ | T-001 |' > "$PDT/plan-review.md"
st set-plan-review APPROVE --evidence .claude/claudehut/tasks/0007-liq/plan-review.md
"$ROOT/bin/claudehut-state" --session s set-plan .claude/claudehut/tasks/0007-liq/plan.md >/dev/null 2>&1 \
  && ok "sensitive predicate: the same plan is ACCEPTED once the APPROVE is recorded" \
  || bad "sensitive predicate: a recorded APPROVE did not unblock set-plan"
rm -rf "$TMP"

# ── F6 + F8: the dispatch cost report, and the advisory per-tier budget ────────────────────────────────
# Appended as its own block: this file is being edited concurrently by another agent.
# NOTE on the two traps that have each produced a FALSE GREEN in this repo: every assertion below captures
# command output into a variable and then matches it with `case`, never `… | grep -q`. Under `pipefail`,
# `grep -q` exits on its first match, closes the pipe, the writer dies of SIGPIPE, and the pipeline is
# reported as FAILED — so the assertion goes red on exactly the input it should accept. And no assertion
# here greps a SOURCE file, so none of them can be satisfied by matching an explanatory comment.

echo "== F6: claudehut-state cost-report (read-only dispatch-ledger reader) =="

# A ledger fixture with a REAL orphan stop in it. v0.11 M5 measured one: a stop emitted during compaction
# carrying a fresh agent_id, an EMPTY agent_type, and an agent_transcript_path pointing at a file that was
# never written. A fixture of clean pairs only cannot catch a reader that COUNTS RECORDS instead of joining
# on agent_id, which is the single most likely way this reader is wrong. A torn line is appended too — the
# ledger is a concurrent append target, so a half-written line must cost one record, not the whole report.
mk_ledger() { # $1 = number of PAIRED dispatches; always also writes 1 orphan stop + 1 torn line
  local n="$1" d="$CLAUDE_PROJECT_DIR/.claude/claudehut/ledger" i=1
  mkdir -p "$d"; : > "$d/dispatches.jsonl"
  while [ "$i" -le "$n" ]; do
    printf '{"ts":"2026-08-17T10:00:00Z","event":"start","session_id":"s","agent_id":"a%s","agent_type":"claudehut:claudehut-reviewer","cwd":"/p"}\n' "$i" >>"$d/dispatches.jsonl"
    printf '{"ts":"2026-08-17T10:00:07Z","event":"stop","session_id":"s","agent_id":"a%s","agent_type":"claudehut:claudehut-reviewer","effort":"high","agent_transcript_path":"/never/written.jsonl"}\n' "$i" >>"$d/dispatches.jsonl"
    i=$((i+1))
  done
  printf '{"ts":"2026-08-17T10:05:00Z","event":"stop","session_id":"s","agent_id":"ORPHAN-compact","agent_type":"","effort":"","agent_transcript_path":"/never/written.jsonl"}\n' >>"$d/dispatches.jsonl"
  printf '{ this line is torn and unparseable\n' >>"$d/dispatches.jsonl"
}

new_proj; mk_ledger 3
CR="$("$ROOT/bin/claudehut-state" cost-report 2>/dev/null)"
case "$CR" in *"3 dispatch(es) paired on agent_id"*)
  ok "F6: joins start↔stop on agent_id — 3 dispatches from 7 parseable records" ;;
  *) bad "F6: pair count wrong (expected 3 pairs)" ;; esac
case "$CR" in *"1 orphan stop(s) DISCARDED"*)
  ok "F6: the M5 orphan stop is DISCARDED, not counted as a dispatch" ;;
  *) bad "F6: the orphan stop was not discarded" ;; esac
# Pinned on "(unknown)" — the label an EMPTY agent_type would carry into a row — not on the orphan's
# agent_id, which this reader never prints under any mutation and so could not falsify the assertion.
case "$CR" in *"(unknown)"*) bad "F6: the orphan produced a row (empty agent_type reached the table)" ;;
  *) ok "F6: the orphan contributes no row to the report" ;; esac
case "$CR" in *"records 7 "*) ok "F6: the torn line costs one record, not the whole report" ;;
  *) bad "F6: torn line changed the record total (expected 7 of 8 lines parsed)" ;; esac
[ "$("$ROOT/bin/claudehut-state" cost-report --count 2>/dev/null)" = "3" ] \
  && ok "F6: --count is the PAIRED dispatch count (3), not the record count" || bad "F6: --count counted records"
rm -rf "$TMP"

# READ-ONLY, with teeth: no state dir may appear, the ledger must be byte-identical, and it must succeed
# with NO --session — which is what proves the verb intercepts ABOVE the --session guard, the
# `mkdir -p "$STATE_DIR"`, the advisory lock, and the unconditional atomic write at the foot of that file.
new_proj; mk_ledger 2
rm -rf "$CLAUDE_PROJECT_DIR/.claude/claudehut/state"
LB="$(shasum "$CLAUDE_PROJECT_DIR/.claude/claudehut/ledger/dispatches.jsonl" 2>/dev/null | awk '{print $1}')"
"$ROOT/bin/claudehut-state" cost-report >/dev/null 2>&1 \
  && ok "F6: read-only — runs WITHOUT --session (the intercept is above the --session guard)" \
  || bad "F6: cost-report demanded --session"
LA="$(shasum "$CLAUDE_PROJECT_DIR/.claude/claudehut/ledger/dispatches.jsonl" 2>/dev/null | awk '{print $1}')"
[ -n "$LB" ] && [ "$LB" = "$LA" ] && ok "F6: read-only — the ledger is byte-identical after reporting" \
  || bad "F6: cost-report mutated the ledger"
[ -d "$CLAUDE_PROJECT_DIR/.claude/claudehut/state" ] \
  && bad "F6: cost-report created a state dir — it is not read-only" \
  || ok "F6: read-only — no state file or state dir created"
rm -rf "$TMP"

# The tuple must stay UN-COLLAPSED (agent_type × model × effort per task), must never print dollars, and
# must mark the two DERIVED columns as derived rather than passing them off as measured.
new_proj
LEDD="$CLAUDE_PROJECT_DIR/.claude/claudehut/ledger"; mkdir -p "$LEDD"
{ printf '{"ts":"2026-08-17T10:00:00Z","event":"start","session_id":"s","agent_id":"x1","agent_type":"claudehut:claudehut-reviewer","cwd":"/p"}\n'
  printf '{"ts":"2026-08-17T10:00:20Z","event":"stop","session_id":"s","agent_id":"x1","agent_type":"claudehut:claudehut-reviewer","effort":"high","agent_transcript_path":"/never/written.jsonl"}\n'
  printf '{"ts":"2026-08-17T10:00:00Z","event":"start","session_id":"s","agent_id":"x2","agent_type":"claudehut:claudehut-explorer","cwd":"/p"}\n'
  printf '{"ts":"2026-08-17T10:00:05Z","event":"stop","session_id":"s","agent_id":"x2","agent_type":"claudehut:claudehut-explorer","effort":"low","agent_transcript_path":"/never/written.jsonl"}\n'
  printf '{"ts":"2026-08-17T11:00:00Z","event":"start","session_id":"other","agent_id":"y1","agent_type":"Explore","cwd":"/p"}\n'
  printf '{"ts":"2026-08-17T11:00:09Z","event":"stop","session_id":"other","agent_id":"y1","agent_type":"Explore","effort":"low","agent_transcript_path":"/never/written.jsonl"}\n'
} > "$LEDD/dispatches.jsonl"
printf '{"session":"s","task":null,"plan_path":".claude/claudehut/tasks/0042-cost/plan.md"}\n' \
  > "$CLAUDE_PROJECT_DIR/.claude/claudehut/state/s.json"
CR="$("$ROOT/bin/claudehut-state" cost-report 2>/dev/null)"
ROW_REV="$(printf '%s\n' "$CR" | grep 'claudehut:claudehut-reviewer' || true)"
ROW_EXP="$(printf '%s\n' "$CR" | grep 'claudehut:claudehut-explorer' || true)"
{ [ -n "$ROW_REV" ] && [ -n "$ROW_EXP" ]; } \
  && ok "F6: the tuple stays UN-COLLAPSED — one row per (task × agent_type × effort)" \
  || bad "F6: rows collapsed — two agent types did not produce two rows"
case "$ROW_REV" in *opus~*) ok "F6: model~ derived from agents/<name>.md frontmatter, marked derived on the VALUE" ;;
  *) bad "F6: reviewer row missing the derived opus~ model" ;; esac
case "$ROW_EXP" in *haiku~*) ok "F6: a second agent type resolves to its own frontmatter model (haiku~)" ;;
  *) bad "F6: explorer row missing the derived haiku~ model" ;; esac
ROW_BUILTIN="$(printf '%s\n' "$CR" | grep -w 'Explore' || true)"
case "$ROW_BUILTIN" in *'~'*) bad "F6: a built-in agent was given a derived model it does not have" ;;
  *) ok "F6: a built-in agent type (no frontmatter) reports '-', never an invented model" ;; esac
case "$ROW_REV" in *high*) ok "F6: effort is reported from the SubagentStop record, unmarked (observed)" ;;
  *) bad "F6: effort column missing" ;; esac
case "$CR" in *"0042-cost~"*) ok "F6: task~ derived from the session state file, marked derived" ;;
  *) bad "F6: task column did not resolve from the state file" ;; esac
# Matched against the ROW, not the whole report: the footnote also contains the word "(unresolved)", so a
# whole-output match here was green even after a revert-to-red that invented a task dir. Caught by the drill.
case "$ROW_BUILTIN" in *"(unresolved)"*) ok "F6: a session with no surviving state file reports (unresolved), not a guess" ;;
  *) bad "F6: unresolvable task dir was not labelled in its row" ;; esac
case "$CR" in *"CLAUDE_CODE_SUBAGENT_MODEL"*)
  ok "F6: the output itself says the derived model column can be wrong at runtime" ;;
  *) bad "F6: derived model presented without its caveat" ;; esac
case "$CR" in *'$'*) bad "F6: the report printed a dollar sign — it cannot price a dispatch" ;;
  *) ok "F6: prints no dollars anywhere" ;; esac
case "$CR" in *"CANNOT price a dispatch"*) ok "F6: states plainly that no hook payload carries usage/token data" ;;
  *) bad "F6: no statement that the report cannot price a dispatch" ;; esac
case "$CR" in *"/usage"*) case "$CR" in *"query_source"*)
  ok "F6: points at /usage and the OTEL query_source × model × effort grouping for money" ;;
  *) bad "F6: no OTEL grouping pointer" ;; esac ;; *) bad "F6: no /usage pointer" ;; esac
CR_S="$("$ROOT/bin/claudehut-state" --session s cost-report 2>/dev/null)"
case "$CR_S" in *Explore*) bad "F6: --session did not narrow the report to one session" ;;
  *) ok "F6: --session narrows the shared ledger to one session" ;; esac
rm -rf "$TMP"

echo "== F8: advisory per-tier dispatch budget at the Stop gate =="
# Ceilings are gate-done.sh's, derived from the phase→skill map: trivial 9, small 19, full 31.
# THE NON-NEGOTIABLE: the Stop DECISION must be identical at, under and over every tier's budget — a hard
# budget would convert a cost feature into a correctness failure on a legitimate 15-dispatch full-tier task.
# The second half matters just as much: "decision unchanged" alone is satisfied by implementing NOTHING, so
# each tier also asserts the advisory is ABSENT under and at budget (or it becomes wallpaper) and PRESENT
# over it. The "at budget" case is also the orphan guard: each fixture carries one orphan stop, so a budget
# that counted records instead of joining would read ceil+1, fire, and turn that assertion red.
gate_done_out() { echo '{"session_id":"s","stop_hook_active":false}' | "$ROOT/scripts/gate-done.sh" 2>/dev/null; }
f8_advice() { case "$1" in *"dispatches this session"*) return 0 ;; *) return 1 ;; esac; }
for f8t in trivial small full; do
  case "$f8t" in trivial) f8c=9 ;; small) f8c=19 ;; full) f8c=31 ;; esac
  for f8p in under at over; do
    case "$f8p" in under) f8n=$((f8c-1)) ;; at) f8n=$f8c ;; over) f8n=$((f8c+1)) ;; esac
    new_proj; st set-complexity "$f8t"; review_pass; mk_receipt; mk_ledger "$f8n"
    F8OUT="$(gate_done_out)"
    if jq -e '.decision=="block"' <<<"$F8OUT" >/dev/null 2>&1; then
      bad "F8: $f8t tier, $f8p budget ($f8n vs $f8c) — Stop decision CHANGED to block"
    else
      ok "F8: $f8t tier, $f8p budget ($f8n vs $f8c) — Stop decision unchanged (never blocks)"
    fi
    if [ "$f8p" = over ]; then
      f8_advice "$F8OUT" && ok "F8: $f8t tier, $f8n > $f8c — advisory line present" \
                         || bad "F8: $f8t tier, $f8n > $f8c — advisory MISSING"
    else
      f8_advice "$F8OUT" && bad "F8: $f8t tier, $f8p budget ($f8n) — advisory fired on a clean run (wallpaper)" \
                         || ok "F8: $f8t tier, $f8p budget ($f8n) — silent, as required"
    fi
    rm -rf "$TMP"
  done
done
# The advisory must ride the non-blocking systemMessage channel and say so — a user who reads it must not
# think the run was capped, because the platform's own large-workflow warning does not pause or limit either.
new_proj; st set-complexity full; review_pass; mk_receipt; mk_ledger 40
F8OUT="$(gate_done_out)"
F8MSG="$(jq -r '.systemMessage // empty' <<<"$F8OUT" 2>/dev/null || true)"
case "$F8MSG" in *"dispatches this session"*)
  ok "F8: the budget rides systemMessage (non-blocking), not a decision field" ;;
  *) bad "F8: budget advisory absent from systemMessage" ;; esac
case "$F8MSG" in *"nothing was blocked"*) ok "F8: the advisory tells the reader nothing was blocked or limited" ;;
  *) bad "F8: the advisory does not disclaim that it is advisory" ;; esac
rm -rf "$TMP"

echo
echo "RESULT: $PASS passed, $FAIL failed"
# W19: publish the count so reference-check.sh can pin the README number without re-running this suite.
[ -z "${EVAL_COUNT_DIR:-}" ] || printf '%s\n' "$PASS" > "$EVAL_COUNT_DIR/gate-tests.count"
[ "$FAIL" -eq 0 ]
