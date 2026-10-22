#!/usr/bin/env bash
# status-tests.sh — `claudehut status` (M5b; docs/v0.20 08 §2, K9) and the task TTL (04 §1, STA-2):
#   ST1-ST2   no plane is said; packs registered by the SessionStart hook are not flagged, unregistered ones are
#   ST3-ST6   active tasks: phase/tier/age from the last event; stale past ttl_days (default 7, topology overrides);
#             a bash-writer task (no event log) falls back to task.json .updated; ended tasks are not listed
#   ST7-ST8   knowledge: index current vs behind HEAD; the hub's service count and newest sync
#   ST9-ST11  host line from env-profile.json; --selftest runs the canaries; the `claudehut` shim routes only status
# Self-contained temp repos. Prints "STATUS: N passed, M failed"; exit 1 on failure.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
command -v python3 >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || { echo "STATUS: 0 passed, 0 failed (no python3/jq)"; exit 0; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/status tests.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS+1)); echo "ok - $1"; else FAIL=$((FAIL+1)); echo "FAIL - $1"; fi; }
export CLAUDEHUT_HOST_PROBE=0 CLAUDEHUT_INDEX_NO_SPAWN=1
unset CLAUDEHUT_PACKS CLAUDEHUT_HUB CLAUDEHUT_GATE_MODE
CH="$ROOT/bin/claudehut"
st() { local p="$1"; shift; CLAUDE_PROJECT_DIR="$p" "$CH" status --project "$p" "$@"; }
ago() { python3 -c 'import sys,time; print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time()-float(sys.argv[1])*86400)))' "$1"; }

P="$TMP/noplane"; mkdir -p "$P"
out="$(st "$P")"; rc=$?
check "ST1: no plane → said, exit 0 (rc=$rc)" '[ "$rc" = 0 ] && [[ "$out" == *"plane     : none"* ]]'

P="$TMP/repo"; mkdir -p "$P/.claudehut/tasks"
git -C "$P" init -q && git -C "$P" -c user.email=t@t -c user.name=t commit -q --allow-empty -m i
out="$(st "$P")"
check "ST2a: packs not registered here are named as unregistered" '[[ "$out" == *"unregistered: claudehut-kernel"* ]]'
CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$P" bash "$ROOT/scripts/register-packs.sh" </dev/null
out="$(st "$P")"
check "ST2b: after the SessionStart hook ran, no unregistered note" '[[ "$out" != *"unregistered"* ]] && [[ "$out" == *"packs     : claudehut-kernel"* ]]'

id="$(CLAUDE_PROJECT_DIR="$P" "$ROOT/bin/claudehut-state" --session s1 start --route light --slug fresh 2>/dev/null | head -1)"
CLAUDE_PROJECT_DIR="$P" "$ROOT/bin/claudehut-state" --session s1 set-tier T2 --reason "new vendor" 2>/dev/null
out="$(st "$P")"
check "ST3: an active task shows phase, route, tier and its last-event age, not stale" '[[ "$out" == *"task      : $id phase=discover route=light tier=T2"* ]] && [[ "$out" != *STALE* ]]'
TD="$P/.claudehut/tasks/$id"; old="$(ago 10)"
jq -c --arg t "$old" '.ts=$t' "$TD/events.jsonl" >"$TD/e" 2>/dev/null && mv "$TD/e" "$TD/events.jsonl"
jq --arg t "$old" '.updated=$t' "$TD/task.json" >"$TD/t" && mv "$TD/t" "$TD/task.json"   # the bash writer keeps no log
out="$(st "$P")"
check "ST4a: no event for 10 days → STALE (default ttl 7d)" '[[ "$out" == *"$id"*"last_event 10d STALE (no event for >7d)"* ]]'
printf '{"ttl_days": 30}' >"$P/.claudehut/topology.json"
out="$(st "$P" --json)"
check "ST4b: topology ttl_days=30 → not stale" 'jq -e ".ttl_days==30 and (.tasks[0].stale==false)" <<<"$out" >/dev/null'
rm -f "$P/.claudehut/topology.json"
id2="0099-bashtask"; mkdir -p "$P/.claudehut/tasks/$id2"
printf '{"id":"%s","status":"active","phase":"plan","route":"light","updated":"%s"}\n' "$id2" "$(ago 9)" >"$P/.claudehut/tasks/$id2/task.json"
out="$(st "$P" --json)"
check "ST5: a task without an event log uses task.json .updated (9d → stale)" 'jq -e ".tasks[]|select(.id==\"0099-bashtask\" and .stale==true and .age==\"9d\")" <<<"$out" >/dev/null'
CLAUDE_PROJECT_DIR="$P" "$ROOT/bin/claudehut-state" --session s1 end --status abandoned 2>/dev/null
out="$(st "$P" --json)"
check "ST6: an ended task is not listed" '! jq -e ".tasks[]|select(.id==\"$id\")" <<<"$out" >/dev/null'

head="$(git -C "$P" rev-parse HEAD)"; mkdir -p "$P/.claudehut/index"
printf '{"schema":1,"indexed_commit":"%s"}' "$head" >"$P/.claudehut/index/meta.json"
out="$(st "$P")"
check "ST7a: index at HEAD → current" '[[ "$out" == *"knowledge : index @${head:0:7} (current)"* ]]'
git -C "$P" -c user.email=t@t -c user.name=t commit -q --allow-empty -m two
out="$(st "$P")"
check "ST7b: HEAD moved → behind HEAD" '[[ "$out" == *"(behind HEAD)"* ]]'
H="$TMP/hubroot"; mkdir -p "$H/.claudehut/hub"; printf '{"schema":1}' >"$H/.claudehut/hub/hub.json"
printf '{"a-ms":{"synced_at":"2026-10-01T00:00:00Z"},"b-ms":{"synced_at":"2026-10-20T00:00:00Z"}}' >"$H/.claudehut/hub/services.json"
out="$(CLAUDEHUT_HUB="$H" st "$P")"
check "ST8: the hub line counts services and names the newest sync" '[[ "$out" == *"hub 2 services, newest sync 2026-10-20T00:00:00Z"* ]]'

printf '{"schema":1,"at":"2026-10-22T00:00:00Z","auth_mode":"plan","bash_hooks":[],"rewriters":0}' >"$P/.claudehut/state/env-profile.json"
out="$(st "$P")"
check "ST9: host line from the probed env-profile" '[[ "$out" == *"host      : auth plan, Bash-rewriting hooks 0 (probed 2026-10-22T00:00:00Z)"* ]]'
out="$(st "$P" --selftest)"; rc=$?
n="$(grep -oE '[0-9]+/[0-9]+ canaries alive' <<<"$out")"
check "ST10: --selftest runs every canary ($n, rc=$rc)" '[ "$rc" = 0 ] && [ -n "$n" ] && [ "${n%%/*}" = "$(cut -d" " -f1 <<<"${n#*/}")" ]'
"$CH" frobnicate >/dev/null 2>&1; rc=$?
check "ST11: the claudehut shim routes only status (other verb → usage, rc=$rc)" '[ "$rc" = 2 ]'

echo "STATUS: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
