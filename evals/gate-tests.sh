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
echo scan > "$chd/reuse-scan-x.md"; st set-reuse-scan --artifact "$chd/reuse-scan-x.md"
denies x "$PROD" && ok "deny: reuse ok, no spec" || bad "deny: no spec"
echo spec > "$chd/specs/x.md"; st set-spec "$chd/specs/x.md"
denies x "$PROD" && ok "deny: spec ok, no plan" || bad "deny: no plan"
echo plan > "$chd/plans/x.md"; st set-plan "$chd/plans/x.md"
allows x "$PROD" && ok "allow: reuse+spec+plan all set (files exist)" || bad "allow: all set"
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
new_proj; st set-phase implement
blocks x '{"session_id":"s","stop_hook_active":false}' && ok "block: review pending (engaged)" || bad "block: pending"
st set-review pass; blocks x '{"session_id":"s","stop_hook_active":false}' && ok "block: review pass but phase!=learn" || bad "block: phase!=learn"
st set-phase learn; done_ok x '{"session_id":"s","stop_hook_active":false}' && ok "allow: review=pass + phase=learn" || bad "allow: done"
st set-review pending; done_ok x '{"session_id":"s","stop_hook_active":true}' && ok "allow: stop_hook_active cap" || bad "cap allow"
done_ok x '{"session_id":"none","stop_hook_active":false}' && ok "allow: missing state fails open (no block)" || bad "done fail-open"
rm -rf "$TMP"

echo "== verify-subagent =="
new_proj
echo '{"agent_type":"claudehut-reuse-scanner"}' | "$ROOT/scripts/verify-subagent.sh" | jq -e '.decision=="block"' >/dev/null 2>&1 && ok "block: reuse-scanner, no artifact" || bad "block: scanner"
touch "$CLAUDE_PROJECT_DIR/.claude/claudehut/reuse-scan-x.md"
[ -z "$(echo '{"agent_type":"claudehut-reuse-scanner"}' | "$ROOT/scripts/verify-subagent.sh")" ] && ok "allow: reuse-scanner with artifact" || bad "allow: scanner artifact"
[ -z "$(echo '{"agent_type":"claudehut-reviewer"}' | "$ROOT/scripts/verify-subagent.sh")" ] && ok "allow: text agent (reviewer)" || bad "allow: text agent"
rm -rf "$TMP"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
