#!/usr/bin/env bash
# IDEA-R16 — the single-message acceptance test: does the bootstrap actually fire?
#
# Every other eval drives the scripts directly, which is exactly the blind spot: a script can be perfect and
# never be invoked. This drives a REAL session with one ordinary Java request.
#
# v0.12 (M1) contract, which inverts two v0.11 assertions on purpose:
#   - SessionStart context reaches the session (the transcript carries it, with the "Session id:" line)
#   - nothing is armed: no state/<sid>.json unless the model itself ran `claudehut-state start` (then schema 2)
#   - no hook denies or blocks anything, and no hook error is recorded
# The plane is created with claudehut-init first: v0.12 hooks stay silent in a repo without one.
#
# NOT part of the deterministic suite. It starts a real session, so it costs tokens and needs auth — the
# same constraint scripts/load-probe.sh carries. Run it as a release-checklist step.
#
# Usage: evals/bootstrap-acceptance.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok(){  PASS=$((PASS+1)); echo "  ok   - $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  FAIL - $1"; }

command -v claude >/dev/null 2>&1 || { echo "SKIP: claude CLI not on PATH"; exit 0; }
command -v jq     >/dev/null 2>&1 || { echo "SKIP: jq required"; exit 0; }

W="$(mktemp -d)/repo"
mkdir -p "$W/src/main/java/com/example/pay"
cat > "$W/src/main/java/com/example/pay/PaymentClient.java" <<'JAVA'
package com.example.pay;

public class PaymentClient {
    public String capture(String orderId) {
        return "captured:" + orderId;
    }
}
JAVA
printf 'dependencies { implementation("org.springframework.boot:spring-boot-starter-web") }\n' > "$W/build.gradle.kts"
( cd "$W" && git init -q 2>/dev/null )
CLAUDE_PROJECT_DIR="$W" "$ROOT/bin/claudehut-init" "$W" >/dev/null 2>&1 || true

echo "== IDEA-R16: one ordinary Java request, real session =="
R="$W/.stream.jsonl"
# A whole real session under bypassPermissions — the riskiest headless call in this repo, and the one that
# most needs a ceiling. The number is a LITERAL and deliberately generous (it matches run.sh's whole-session
# default): a cap that truncates the session mid-run leaves a short-but-non-empty stream, which sails past
# the empty-stream SKIP below and reports the probe's assertions as FAIL. Do not lower it, and do not wire it to
# CLAUDEHUT_EVAL_BUDGET — the playbook probes default that knob to 1.00, which would false-RED this probe.
( cd "$W" && claude -p "Add a retry to the payment client." \
    --plugin-dir "$ROOT" \
    --permission-mode bypassPermissions \
    --max-budget-usd 3.00 \
    --output-format stream-json --verbose > "$R" 2>/dev/null )

if [ ! -s "$R" ]; then
  echo "  SKIP - no stream produced (auth? network?) — this probe cannot self-certify"; rm -rf "$W"; exit 0
fi

SID="$(jq -r 'select(.type=="system" and .subtype=="init") | .session_id' "$R" 2>/dev/null | head -1)"
TR="$(ls "$HOME"/.claude/projects/*/"$SID".jsonl 2>/dev/null | head -1)"
if [ -n "$SID" ] && [ -n "$TR" ] \
   && jq -e --arg s "Session id: $SID" 'select(.attachment.type=="hook_additional_context" and .attachment.hookEvent=="SessionStart")
        | .attachment.content | (if type=="array" then join("\n") else tostring end) | contains($s)' "$TR" >/dev/null 2>&1; then
  ok "SessionStart context reached the session (transcript carries 'Session id: $SID')"
else
  bad "no ClaudeHut SessionStart context in the transcript (sid=${SID:-none}) — the bootstrap did not fire"
fi

if grep -qE 'ClaudeHut gate|permissionDecision\\?":\\?"deny|hook error' "$R" 2>/dev/null; then
  bad "a hook denied, blocked or errored during the session"
else
  ok "no hook denied, blocked or errored"
fi

SF="$W/.claude/claudehut/state/$SID.json"
if [ ! -e "$SF" ]; then
  ok "nothing was armed: no state/<sid>.json (the model did not open a task)"
elif jq -e '.schema==2' "$SF" >/dev/null 2>&1; then
  ok "the only state is a schema-2 pointer the model created with claudehut-state start"
else
  bad "a non-schema-2 state file appeared — something armed v0.11 state"
fi

[ -s "$W/.claude/claudehut/state/hook-errors.log" ] \
  && bad "hook-errors.log is not empty: $(head -c 200 "$W/.claude/claudehut/state/hook-errors.log")" \
  || ok "hook-errors.log is empty"

rm -rf "$W"
echo; echo "BOOTSTRAP-ACCEPTANCE: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
