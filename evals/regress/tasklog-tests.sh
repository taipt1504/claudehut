#!/usr/bin/env bash
# tasklog-tests.sh — K1 event log as the source of truth (claudehut_kernel/tasklog.py, docs/v0.20 04 §1, M1b-b):
#   E1  every transition appends exactly one state event; a refused transition appends none
#   E2  a 0.12 task (task.json, no log) is imported as a snapshot on its first write, then replays
#   E3  a task.json changed by another writer (the bash fallback, a hand edit) is imported, never overwritten blindly
#   E4  a crash between the append and the task.json write: the next writer re-projects from the log first
#   E5  the informational review.verdict / task.ended lines the 0.12.7 gate CLI wrote never change the projection
# Prints "TASKLOG: N passed, M failed"; exit 1 on failure.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CS="$ROOT/bin/claudehut-state"; K="$ROOT/bin/claudehut-kernel"
command -v python3 >/dev/null 2>&1 || { echo "TASKLOG: 0 passed, 0 failed (no python3)"; exit 0; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/tasklog.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS+1)); echo "ok - $1"; else FAIL=$((FAIL+1)); echo "FAIL - $1"; fi; }
export CLAUDEHUT_HOST_PROBE=0 CLAUDEHUT_STATE_SELFCHECK=1 CLAUDEHUT_STATE_IMPL=py   # the event log is the Python writer's
repo() { local p="$TMP/$1"; mkdir -p "$p/.claudehut"; git -C "$p" init -q; printf '%s' "$p"; }
cs() { local p="$1" s="$2"; shift 2; CLAUDE_PROJECT_DIR="$p" "$CS" --session "$s" "$@"; }
nstate() { jq -c 'select(has("rev"))' "$1/events.jsonl" 2>/dev/null | grep -c . ; }

P="$(repo e1)"; id="$(cs "$P" a start --route light --slug x 2>/dev/null | head -1)"; TD="$P/.claudehut/tasks/$id"
cs "$P" a set-phase implement 2>/dev/null; cs "$P" a set-profile bugfix 2>/dev/null
check "E1: start + 2 transitions → 3 state events, revs 1..3, task.json event_rev 3" \
  '[ "$(nstate "$TD")" = 3 ] && [ "$(jq -sc "map(select(has(\"rev\"))|.rev)" "$TD/events.jsonl")" = "[1,2,3]" ] && [ "$(jq .event_rev "$TD/task.json")" = 3 ]'
check "E1: typed events (task.started, phase.entered, profile.set) carrying the session" \
  '[ "$(jq -rsc "map(select(has(\"rev\"))|.type+\":\"+.session)|join(\",\")" "$TD/events.jsonl")" = "task.started:a,phase.entered:a,profile.set:a" ]'
before="$(cat "$TD/task.json")"
cs "$P" a set-profile nonsense 2>/dev/null; cs "$P" a set-spec .claudehut/tasks/$id/missing.md 2>/dev/null
check "E1: refused transitions append no state event and leave task.json byte-identical" \
  '[ "$(nstate "$TD")" = 3 ] && [ "$(cat "$TD/task.json")" = "$before" ]'
check "E1: replay --check reproduces task.json" '"$K" replay --task "$TD" --check 2>/dev/null'

P="$(repo e2)"; mkdir -p "$P/.claudehut/tasks/0001-old" "$P/.claudehut/state"; TD="$P/.claudehut/tasks/0001-old"
printf '{"schema":2,"id":"0001-old","route":"light","profile":null,"phase":"plan","plan_approved":false,"review":"pending","plan_review_round":0,"doc_schema":2,"base":{".":null},"pre_dirty":{".":[]},"scope":[],"enforcement_set":[],"status":"active","session":"b","created":"2026-01-01T00:00:00Z"}\n' >"$TD/task.json"
printf '{"schema":2,"active_task":"0001-old"}\n' >"$P/.claudehut/state/b.json"
printf '{"ts":"2026-01-01T00:00:01Z","type":"review.verdict","source":"cli","data":{"verdict":"pass","gate":"pass"}}\n{"ts":"2026-01-01T00:00:02Z","type":"task.ended","source":"cli","data":{"status":"done","gate":"pass"}}\n' >"$TD/events.jsonl"
"$K" replay --task "$TD" --check 2>"$TMP/e"; rc=$?
check "E5: a log with only 0.12.7 gate lines has no state event (replay: nothing to project, exit 0)" '[ "$rc" = 0 ] && grep -q "no state event" "$TMP/e"'
cs "$P" b set-phase implement 2>/dev/null
check "E2: the first write of a 0.12 task imports it (task.imported rev 1) then patches (rev 2)" \
  '[ "$(jq -rsc "map(select(has(\"rev\"))|.type)|join(\",\")" "$TD/events.jsonl")" = "task.imported,phase.entered" ] && [ "$(jq -r .phase "$TD/task.json")" = implement ]'
check "E5: the gate lines did not change the projection (review stays pending)" \
  '"$K" replay --task "$TD" --check 2>/dev/null && [ "$(jq -r .review "$TD/task.json")" = pending ]'

P="$(repo e3)"; id="$(cs "$P" c start --route light --slug x 2>/dev/null | head -1)"; TD="$P/.claudehut/tasks/$id"
CLAUDEHUT_STATE_IMPL=bash cs "$P" c set-route full 2>/dev/null       # the fallback writer: task.json only
jq '.outstanding=["hand"]' "$TD/task.json" >"$TD/t" && mv "$TD/t" "$TD/task.json"   # a hand edit
cs "$P" c set-phase spec 2>/dev/null
check "E3: another writer's task.json is imported before the next patch (route full and the hand edit kept)" \
  '[ "$(jq -rsc "map(select(has(\"rev\"))|.type)|join(\",\")" "$TD/events.jsonl")" = "task.started,task.imported,phase.entered" ] && [ "$(jq -c "[.route,.outstanding,.phase]" "$TD/task.json")" = "[\"full\",[\"hand\"],\"spec\"]" ]'
check "E3: … and the log replays to task.json" '"$K" replay --task "$TD" --check 2>/dev/null'

P="$(repo e4)"; id="$(cs "$P" d start --route light --slug x 2>/dev/null | head -1)"; TD="$P/.claudehut/tasks/$id"
cp "$TD/task.json" "$TMP/pre.json"
cs "$P" d set-phase implement 2>/dev/null
cp "$TMP/pre.json" "$TD/task.json"      # simulate: the event landed, the task.json write did not
cs "$P" d set-profile audit 2>/dev/null
check "E4: after a lost task.json write the next writer re-projects first (phase implement survives, no import)" \
  '[ "$(jq -c "[.phase,.profile,.event_rev]" "$TD/task.json")" = "[\"implement\",\"audit\",3]" ] && [ "$(jq -rsc "map(select(has(\"rev\"))|.type)|join(\",\")" "$TD/events.jsonl")" = "task.started,phase.entered,profile.set" ]'

echo "TASKLOG: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
