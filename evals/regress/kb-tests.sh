#!/usr/bin/env bash
# kb-tests.sh — the claudehut-kb MCP server over stdio, no model call (docs/v0.20 05 §4, M3b):
#   B1  protocol: initialize (protocol echoed, instructions), a notification gets NO reply, ping, tools/list (3 tools),
#       unknown method → -32601, a malformed line → -32700, an unknown tool → isError result (not a JSON-RPC error)
#   B2  three states, never confused: unknown (no index), unknown (stack not applicable, with the reason),
#       ok (found) — and none_found on an applicable index that holds nothing
#   B3  stale: a commit after the update → stale:true with the head and the fix
#   B4  kb_patterns without a concern returns every pattern; a concern only ranks ("zns" still lists SmsProvider)
#   B5  concise output stays under the cap; detailed is allowed more; facts carry file:line provenance
#   B6  .mcp.json starts the server through bin/claudehut-kb; a broken python3 fails loudly on stderr
# Prints "KB: N passed, M failed"; exit 1 on failure.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KB="$ROOT/bin/claudehut-kb"; IDX="$ROOT/bin/claudehut-index"
command -v python3 >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || { echo "KB: 0 passed, 0 failed (no python3/jq)"; exit 0; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/kb-tests.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS+1)); echo "ok - $1"; else FAIL=$((FAIL+1)); echo "FAIL - $1"; fi; }
export CLAUDEHUT_HOST_PROBE=0 CLAUDEHUT_INDEX_NO_SPAWN=1
rpc() { # $1 project, rest: JSON lines → server output lines
  local p="$1"; shift
  printf '%s\n' "$@" | CLAUDE_PROJECT_DIR="$p" "$KB" 2>>"$TMP/kb.err"
}
call() { # $1 project $2 tool $3 arguments JSON → the tool's text payload (parsed JSON)
  rpc "$1" "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"tools/call\",\"params\":{\"name\":\"$2\",\"arguments\":$3}}" | jq -r '.result.content[0].text'
}
repo() { # $1 name $2 source dir (copied) → a git repo with a .claudehut plane
  local d="$TMP/$1"; mkdir -p "$d"; [ -n "${2:-}" ] && cp -R "$2/." "$d/"; mkdir -p "$d/.claudehut"
  git -C "$d" init -q && git -C "$d" add -A && git -C "$d" -c user.email=t@t -c user.name=t commit -qm x --allow-empty; printf '%s' "$d"
}

J="$(repo java "$ROOT/evals/fixtures/variation/repo")"
out="$(rpc "$J" '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' '{"jsonrpc":"2.0","id":2,"method":"ping"}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/list"}' '{"jsonrpc":"2.0","id":4,"method":"nope"}' 'not json' \
  '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"kb_nothing","arguments":{}}}')"
check "B1: initialize echoes a supported protocol and carries the server instructions" \
  'jq -se ".[0].result.protocolVersion==\"2025-03-26\" and (.[0].result.instructions|test(\"BEFORE adding an interface\"))" <<<"$out" >/dev/null'
check "B1: 6 replies for 7 lines — the notification is never answered" '[ "$(grep -c . <<<"$out")" = 6 ]'
check "B1: ping → {}; tools/list → kb_variation_points, kb_patterns, kb_brief" \
  'jq -se "(.[1].result=={}) and ([.[2].result.tools[].name]==[\"kb_variation_points\",\"kb_patterns\",\"kb_brief\"])" <<<"$out" >/dev/null'
check "B1: unknown method → -32601; malformed line → -32700; unknown tool → isError result" \
  'jq -se "(.[3].error.code==-32601) and (.[4].error.code==-32700) and (.[5].result.isError==true)" <<<"$out" >/dev/null'

u="$(CLAUDEHUT_KB_NO_BUILD=1 call "$J" kb_variation_points '{}')"
check "B2: no index (first-use build off) → status unknown with the fix (never none_found)" '[ "$(jq -r .status <<<"$u")" = unknown ] && jq -r .fix <<<"$u" | grep -q "claudehut-index update"'
J2="$(repo java2 "$ROOT/evals/fixtures/variation/repo")"
f="$(call "$J2" kb_variation_points '{}')"
check "B2: a never-indexed plane is built once on first use → status ok" '[ "$(jq -r .status <<<"$f")" = ok ] && [ -f "$J2/.claudehut/index/variation.json" ]'
"$IDX" update --plane "$J/.claudehut" >/dev/null 2>&1
v="$(call "$J" kb_variation_points '{"scope":"bank export"}')"
check "B2: indexed Java repo → status ok, stale false, the bank parameter ranked first for scope 'bank export'" \
  '[ "$(jq -r .status <<<"$v")" = ok ] && [ "$(jq -r .stale <<<"$v")" = false ] && jq -r ".results[0].anchor" <<<"$v" | grep -qiE "bank|export"'
PY="$(repo py)"; printf 'print(1)\n' >"$PY/a.py"; git -C "$PY" add -A; git -C "$PY" -c user.email=t@t -c user.name=t commit -qm py
"$IDX" update --plane "$PY/.claudehut" >/dev/null 2>&1
n="$(call "$PY" kb_variation_points '{}')"
check "B2: Python repo → unknown, 'not applicable here' with the pack named" '[ "$(jq -r .status <<<"$n")" = unknown ] && jq -r .reason <<<"$n" | grep -q "lang-java-spring"'
E="$(repo empty)"; mkdir -p "$E/src/main/java/x"; printf 'package x;\npublic class Only {}\n' >"$E/src/main/java/x/Only.java"; printf 'apply plugin: "java"\n' >"$E/build.gradle"
git -C "$E" add -A; git -C "$E" -c user.email=t@t -c user.name=t commit -qm e; "$IDX" update --plane "$E/.claudehut" >/dev/null 2>&1
z="$(call "$E" kb_variation_points '{}')"
check "B2: applicable index holding nothing → none_found (distinct from unknown)" '[ "$(jq -r .status <<<"$z")" = none_found ]'

printf 'x\n' >"$J/NEW.txt"; git -C "$J" add -A; git -C "$J" -c user.email=t@t -c user.name=t commit -qm later
s="$(call "$J" kb_variation_points '{}')"
check "B3: a commit after the update → stale:true with head and fix" '[ "$(jq -r .stale <<<"$s")" = true ] && [ -n "$(jq -r .head <<<"$s")" ] && jq -r .fix <<<"$s" | grep -q update'

p0="$(call "$J" kb_patterns '{}')"; p1="$(call "$J" kb_patterns '{"concern":"zns sender"}')"
check "B4: kb_patterns without a concern returns the port-selector pattern with 4 instances" '[ "$(jq ".results[0].instances|length" <<<"$p0")" = 4 ]'
check "B4: an unrelated concern ('zns sender') still lists every instance, SmsProvider among them" \
  '[ "$(jq ".results[0].instances|length" <<<"$p1")" = 4 ] && jq -r ".results[0].instances[].anchor" <<<"$p1" | grep -q SmsProvider'

c="$(rpc "$J" '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"kb_variation_points","arguments":{}}}' | jq -r '.result.content[0].text' | wc -c | tr -d ' ')"
check "B5: concise payload ≤ 8000 chars ($c)" '[ "$c" -le 8000 ]'
check "B5: every result carries file:line provenance" '[ -z "$(jq -r ".results[] | select((.at|test(\":[0-9]+$\"))|not) | .anchor" <<<"$v")" ]'
sz="$(rpc "$J" '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | jq -r '(.result.instructions // "") + (.result.tools // [] | tojson)' | wc -c | tr -d ' ')"
check "B5: K-15 budget — server instructions + tool schemas ≤ 2600 chars (~650 tok; $sz). claude plugin details does not count MCP" '[ "$sz" -le 2600 ]'
b="$(call "$J" kb_brief '{"task_text":"refund a card payment"}')"
check "B5: kb_brief returns the brief card (status ok, markdown names a component)" '[ "$(jq -r .status <<<"$b")" = ok ] && jq -r .markdown <<<"$b" | grep -qi refund'

check "B6: .mcp.json starts the server via \${CLAUDE_PLUGIN_ROOT}/bin/claudehut-kb" \
  '[ "$(jq -r ".mcpServers.kb.command" "$ROOT/.mcp.json")" = "\${CLAUDE_PLUGIN_ROOT}/bin/claudehut-kb" ]'
BAD="$TMP/bad"; mkdir -p "$BAD"; printf '#!/bin/sh\nexit 1\n' >"$BAD/python3"; chmod +x "$BAD/python3"
echo '{}' | PATH="$BAD:$PATH" CLAUDE_PROJECT_DIR="$J" "$KB" >/dev/null 2>"$TMP/bad.err"; rc=$?
check "B6: a python3 that cannot run → exit 1 with the reason on stderr (rc=$rc)" '[ "$rc" = 1 ] && grep -q "kb_\* tools are off" "$TMP/bad.err"'
check "B6: no __pycache__ in the plugin" '[ -z "$(find "$ROOT/scripts" -name __pycache__)" ]'

# B7 — the UserPromptSubmit variation hint (scripts/inject-phase.sh, M3c)
ups() { printf '%s' "{\"session_id\":\"u1\",\"prompt\":\"$2\"}" | CLAUDE_PROJECT_DIR="$1" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$ROOT/scripts/inject-phase.sh" 2>/dev/null; }
mkdir -p "$J/.claudehut/state"
h="$(ups "$J" "Add a ZNS sender via GapOne for OTP messages")"
check "B7: an 'add a sender' prompt in an indexed repo gets ONE kb line naming the port-selector instances" \
  'jq -e ".hookSpecificOutput.additionalContext | test(\"port \\\\+ selector: .*SmsProvider\") and test(\"kb_patterns\")" <<<"$h" >/dev/null'
check "B7: … and the endpoint that takes the variant (bank)" 'jq -r ".hookSpecificOutput.additionalContext" <<<"$h" | grep -q "export(bank)"'
q="$(ups "$J" "explain the refund flow")"
check "B7: a prompt that adds nothing gets no hint" '! grep -q "kb: this repo" <<<"$q"'
e="$(mkdir -p "$E/.claudehut/state"; ups "$E" "add a new sms provider")"
check "B7: no variation point in the repo → no hint (silence, not an empty claim)" '! grep -q "kb: this repo" <<<"$e"'
N="$(repo noidx "$ROOT/evals/fixtures/variation/repo")"; mkdir -p "$N/.claudehut/state"
nh="$(ups "$N" "add a new sms provider")"
check "B7: never indexed + a small repo → indexed now, once, and THIS prompt gets the hint" \
  '[ -f "$N/.claudehut/state/index-build.pending" ] && [ -f "$N/.claudehut/index/variation.json" ] && grep -q "kb: this repo" <<<"$nh"'

O="$(repo old "$ROOT/evals/fixtures/variation/repo")"; mkdir -p "$O/.claudehut/state"
"$IDX" update --plane "$O/.claudehut" >/dev/null 2>&1; rm -f "$O/.claudehut/index/variation.json"
oh="$(ups "$O" "add a new sms provider")"
check "B7: an index from before M3 (meta.json, no variation.json) is completed at the prompt and the hint comes" \
  '[ -f "$O/.claudehut/index/variation.json" ] && grep -q "kb: this repo" <<<"$oh"'
rm -f "$O/.claudehut/index/variation.json"; touch -t 202601010000 "$O/.claudehut/state/index-build.pending"
ups "$O" "add a new sms provider" >/dev/null
check "B7: a stale build claim (>10 min, a killed build) does not block the retry" '[ -f "$O/.claudehut/index/variation.json" ]'

# B8 — the write-time variant advisory (scripts/advise-variant.sh, PreToolUse Write(*.java); fires under -p too)
aw() { printf '{"session_id":"%s","tool_name":"Write","tool_input":{"file_path":"%s","content":"x"}}' "$2" "$3" | CLAUDE_PROJECT_DIR="$1" bash "$ROOT/scripts/advise-variant.sh" 2>/dev/null; }
w1="$(aw "$J" w1 "$J/src/main/java/demo/notify/zns/GapOneZnsClient.java")"
check "B8: a NEW *Client class in a repo with port+selector families → one note naming them, with variant dir and selector" \
  'jq -r ".hookSpecificOutput.additionalContext" <<<"$w1" | grep -q "SmsProvider (3 variants in src/main/java/demo/notify/sms/impl, selector SmsProviderFactory)"'
w2="$(aw "$J" w1 "$J/src/main/java/demo/notify/zns/OtherZnsClient.java")"
check "B8: said once per session" '[ -z "$w2" ]'
w3="$(aw "$J" w3 "$J/src/main/java/demo/notify/sms/impl/CmcSmsProvider.java")"
check "B8: editing an EXISTING class is not a decision → silent" '[ -z "$w3" ]'
w7="$(printf '%s' '{"session_id":"w7","tool_name":"Write","tool_input":{"file_path":"'"$J"'/src/main/java/demo/notify/ZnsService.java","content":"class ZnsService { void send() { http.post(\"https://api.vendor.example/zns/send\"); } }"}}' | CLAUDE_PROJECT_DIR="$J" bash "$ROOT/scripts/advise-variant.sh" 2>/dev/null)"
check "B8: a new *Service whose body calls an external URL is an integration too → the note" 'grep -q "ZnsService looks like a new variant" <<<"$w7"'
w4="$(aw "$J" w4 "$J/src/main/java/demo/report/MonthlyReport.java")"
check "B8: a new class without a variant-like name → silent" '[ -z "$w4" ]'
NI="$(repo noidx2 "$ROOT/evals/fixtures/variation/repo")"; mkdir -p "$NI/.claudehut/state"
w6="$(aw "$NI" w6 "$NI/src/main/java/demo/notify/zns/GapOneZnsClient.java")"
check "B8: a never-indexed small repo is indexed at the write and the note still comes (what a fresh eval workspace needs)" \
  '[ -f "$NI/.claudehut/index/variation.json" ] && grep -q "looks like a new variant" <<<"$w6"'
w5="$(aw "$PY" w5 "$PY/src/main/java/x/FooClient.java")"
check "B8: no applicable variation index → silent" '[ -z "$w5" ]'

echo "KB: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
