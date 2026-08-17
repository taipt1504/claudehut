#!/usr/bin/env bash
# IDEA-R16 — the single-message acceptance test: does the bootstrap actually fire?
#
# The write gate, the skill rail and the profile gate are all dead if the SessionStart hook silently stops
# firing, and nothing else detects that. Every other eval drives the scripts directly, which is exactly the
# blind spot: a script can be perfect and never be invoked. This drives a REAL session with one ordinary
# Java request and asserts the plane engaged before any production write happened.
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

echo "== IDEA-R16: one ordinary Java request, real session =="
R="$W/.stream.jsonl"
( cd "$W" && claude -p "Add a retry to the payment client." \
    --plugin-dir "$ROOT" \
    --permission-mode bypassPermissions \
    --output-format stream-json --verbose > "$R" 2>/dev/null )

if [ ! -s "$R" ]; then
  echo "  SKIP - no stream produced (auth? network?) — this probe cannot self-certify"; rm -rf "$W"; exit 0
fi

# Ordinal of the first claudehut skill invocation, and of the first production write. The assertion is the
# ORDER, not the presence: a discover that happens after the edit is the same failure as no discover.
ord_skill="$(jq -rc 'select(.type=="assistant")|.message.content[]?|select(.type=="tool_use")
                     |((.name//"") + " " + ((.input.skill//"")|tostring))' "$R" 2>/dev/null \
             | grep -n 'claudehut' | head -1 | cut -d: -f1)"
ord_write="$(jq -rc 'select(.type=="assistant")|.message.content[]?|select(.type=="tool_use")
                     |((.name//"") + " " + ((.input.file_path//"")|tostring))' "$R" 2>/dev/null \
             | grep -nE '^(Write|Edit|MultiEdit) .*src/main/' | head -1 | cut -d: -f1)"

[ -n "$ord_skill" ] \
  && ok "a claudehut skill was invoked in an ordinary session (SessionStart fired)" \
  || bad "NO claudehut skill was invoked — the bootstrap did not engage; the gates are inert"

if [ -z "$ord_write" ]; then
  ok "no production write happened without the workflow (nothing to order against)"
elif [ -n "$ord_skill" ] && [ "$ord_skill" -lt "$ord_write" ]; then
  ok "the skill invocation precedes the first src/main write"
else
  bad "a src/main write happened before any claudehut skill — the write gate did not hold"
fi

# The plane itself must exist afterwards; a session that engaged but wrote no state is half-armed.
[ -d "$W/.claude/claudehut/state" ] && [ -n "$(ls -A "$W/.claude/claudehut/state" 2>/dev/null)" ] \
  && ok "the session left state behind (the plane was armed, not just mentioned)" \
  || bad "no state was written — bootstrap ran no generator and armed no gate"

rm -rf "$W"
echo; echo "BOOTSTRAP-ACCEPTANCE: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
