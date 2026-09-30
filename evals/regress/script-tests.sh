#!/usr/bin/env bash
# script-tests.sh — regression pins for four hook/script defects fixed in M1 (review round 3):
#   V3-C1  record-failure.sh  stale-lock steal must re-check under a token, never delete a FRESH lock
#   V3-C2  verify-subagent.sh / record-dispatch.sh  numeric fields are tostring'd before jq slicing
#   V3-C3  lint-reuse.sh  project-path prefix stripped by shell expansion, not a sed regex
#   V3-5   merge-learnings.sh  the flock branch must not redirect the script's stderr for the rest of the run
# Deterministic, no Claude, < 60 s (the V3-C1 case waits out its ~2 s fail-open cap).
#
# Run: evals/regress/script-tests.sh
#      SCRIPT_TESTS_SCRIPTS_DIR=<copy of scripts/> …   (point at a modified copy, e.g. to prove a pin fails)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
S="${SCRIPT_TESTS_SCRIPTS_DIR:-$ROOT/scripts}"
export CLAUDE_PLUGIN_ROOT="$ROOT"
unset CLAUDE_ENV_FILE CLAUDEHUT_SESSION_ID CLAUDEHUT_HUB CLAUDEHUT_DEBUG_PAYLOAD CLAUDEHUT_FEDERATION_ROOT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; }
chk() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

# hook <script> <project> <payload> [VAR=value …] → OUT, RC (hook contract: exit 0, ≤1 JSON object on stdout)
hook() {
  local s="$1" p="$2" pl="$3"; shift 3
  OUT="$(printf '%s' "$pl" | env CLAUDE_PROJECT_DIR="$p" "$@" bash "$S/$s.sh" 2>/dev/null)"; RC=$?
  if [ "$RC" -ne 0 ] || ! printf '%s' "$OUT" | jq -se 'length<=1 and all(.[]; type=="object")' >/dev/null 2>&1; then
    bad "contract: $s rc=$RC stdout=$(printf '%s' "$OUT" | head -c 160)"
  fi
}
new_plane() { local p="$W/$1"; mkdir -p "$p/.claude/claudehut"; printf '%s' "$p"; }
errlog_empty() { [ ! -s "$1/.claude/claudehut/state/hook-errors.log" ]; }

echo "== V3-C2: numeric payload fields do not throw in the ledger hooks"
P="$(new_plane led)"; LG="$P/.claude/claudehut/ledger/dispatches.jsonl"
hook verify-subagent "$P" '{"session_id":"s1","agent_type":"planner-1","agent_id":7,"effort":{"level":3}}'
chk "verify-subagent: effort.level=3, agent_id=7 → stop record written with effort \"3\", agent_id \"7\"" \
  "jq -se 'map(select(.event==\"stop\")) | length==1 and .[0].effort==\"3\" and .[0].agent_id==\"7\"' \"\$LG\" >/dev/null 2>&1"
hook record-dispatch "$P" '{"session_id":"s1","agent_type":"planner-1","agent_id":7,"cwd":5}'
chk "record-dispatch: agent_id=7, cwd=5 → start record written with agent_id \"7\"" \
  "jq -se 'map(select(.event==\"start\")) | length==1 and .[0].agent_id==\"7\"' \"\$LG\" >/dev/null 2>&1"
chk "ledger hooks: nothing in hook-errors.log" "errlog_empty \"\$P\""

echo "== V3-C3: a '#', '&', '.' or '*' in the project path does not break the duplicate-helper suspect"
for nm in 'p lr #1' 'p lr &.*'; do
  P="$W/$nm"; A="$P/.claude/claudehut"; J="$P/src/main/java/a"
  mkdir -p "$A/state" "$A/tasks/0001-t" "$J"
  printf '{"schema":2,"active_task":"0001-t"}\n' > "$A/state/s1.json"
  jq -nc '{schema:2,id:"0001-t",route:"light",profile:null,phase:"implement",plan_approved:true,review:"pending",
    plan_review_round:0,base:{},pre_dirty:{},scope:["src/main/*","*/src/main/*"],enforcement_set:[],status:"active"}' \
    > "$A/tasks/0001-t/task.json"
  printf 'package a;\nclass A { static int helperX(int a) { return a; } }\n' > "$J/A.java"
  printf 'package a;\nclass B { static int helperX(int a) { return a; } }\n' > "$J/B.java"
  hook lint-reuse "$P" "$(jq -nc --arg f "$J/A.java" '{session_id:"s1",tool_name:"Write",tool_input:{file_path:$f}}')"
  SJ="$A/state/0001-t.suspects.jsonl"
  chk "lint-reuse ['$nm']: suspect names src/main/java/a/B.java, relative" \
    "jq -se 'map(select(.kind==\"duplicate\")) | length==1 and (.[0].detail | contains(\"also declared in: src/main/java/a/B.java \"))' \"\$SJ\" >/dev/null 2>&1"
  chk "lint-reuse ['$nm']: nothing in hook-errors.log" "errlog_empty \"\$P\""
done

echo "== V3-5: merge-learnings' flock branch keeps the script's stderr"
# A python fcntl `flock` forces the flock branch on macOS too; a `jq` wrapper writes a marker to stderr on every
# call. No jq runs before acquire_lock on this path, so the marker reaches stderr only if stderr survived it.
REALJQ="$(command -v jq)"; SH="$W/shim"; mkdir -p "$SH"
cat > "$SH/flock" <<'FLEOF'
#!/usr/bin/env python3
import fcntl, sys, time
a = sys.argv[1:]; w = None
if a and a[0] == "-w": w = float(a[1]); a = a[2:]
fd = int(a[0]); end = time.time() + (w if w is not None else 1e9)
while True:
    try: fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB); sys.exit(0)
    except OSError:
        if time.time() > end: sys.exit(1)
        time.sleep(0.005)
FLEOF
printf '#!/bin/sh\necho JQ-STDERR-MARK >&2\nexec "%s" "$@"\n' "$REALJQ" > "$SH/jq"
chmod +x "$SH/flock" "$SH/jq"
P="$(new_plane ml)"; C="$W/cand.jsonl"
printf '%s\n' '{"category":"pitfall","trigger":"spring bean cycle","learning":"`@Lazy` breaks a `FooService` cycle","evidence":"FooService.java:12"}' > "$C"
ERR="$(cd "$P" && CLAUDE_PROJECT_DIR="$P" PATH="$SH:$PATH" bash "$S/merge-learnings.sh" --candidates "$C" 2>&1 >/dev/null)"
chk "merge-learnings (flock path): stderr of the merge's jq calls still reaches stderr" \
  "printf '%s' \"\$ERR\" | grep -q JQ-STDERR-MARK"
chk "merge-learnings (flock path): the merge still landed" "[ -s \"\$P/.claude/claudehut/learnings.jsonl\" ]"

echo "== V3-C1: record-failure's stale-lock steal never deletes a FRESH lock taken in the meantime"
# A `stat` wrapper reports the planted lock as 2020-old ONCE, and in that same call replaces it with a fresh lock
# owned by nonce "fresh" — another waiter stole the stale lock and a new writer took it between this waiter's
# look and its removal. A steal decided from that one look deletes the fresh lock; the fix re-checks it (owner
# nonce and age) under a steal token and leaves it alone.
# The fresh lock is never released, so the hook runs its whole fail-open loop against it; a background toucher
# keeps its mtime current until the hook exits (bounded at 60 s), so under load it never ages into a genuinely
# stale lock that record-failure would rightly steal (RG-1).
P="$(new_plane rf)"; SD="$P/.claude/claudehut/state"; mkdir -p "$SD"
L="$SD/s1.failures.jsonl.lock"; mkdir "$L"; printf dead > "$L/o"; touch -t 202001010000 "$L"
REALSTAT="$(command -v stat)"; SS="$W/statshim"; mkdir -p "$SS"
cat > "$SS/stat" <<EOF
#!/bin/sh
for a in "\$@"; do last="\$a"; done
if [ "\$last" = "$L" ] && mkdir "$W/stat.once" 2>/dev/null; then
  /bin/rm -rf "$L"; /bin/mkdir "$L"; printf fresh > "$L/o"
  ( n=0; while [ ! -e "$W/rf.stop" ] && [ \$n -lt 240 ]; do /usr/bin/touch -c "$L"; /bin/sleep 0.25; n=\$((n+1)); done ) >/dev/null 2>&1 &
  case "\$1" in -c) echo 1577836800 ;; -f) echo 1577836800 ;; esac
  exit 0
fi
exec "$REALSTAT" "\$@"
EOF
chmod +x "$SS/stat"
hook record-failure "$P" '{"session_id":"s1","tool_name":"Bash","tool_input":{"command":"cmd 1"},"error":"Exit code 1\nx"}' \
  PATH="$SS:$PATH"
: > "$W/rf.stop"
chk "record-failure: the wrapper fired (the scenario really ran)" "[ -d \"\$W/stat.once\" ]"
chk "record-failure: the fresh lock (nonce \"fresh\") survives the stale-steal attempt" \
  "[ \"\$(cat \"\$L/o\" 2>/dev/null)\" = fresh ]"

# Plain stale lock, no interleaving: it is still stolen and the record lands (the fix must not stop steals).
P="$(new_plane rf2)"; SD="$P/.claude/claudehut/state"; mkdir -p "$SD"
L2="$SD/s1.failures.jsonl.lock"; mkdir "$L2"; printf dead > "$L2/o"; touch -t 202001010000 "$L2"
hook record-failure "$P" '{"session_id":"s1","tool_name":"Bash","tool_input":{"command":"cmd 2"},"error":"Exit code 1\nx"}'
chk "record-failure: a genuinely stale lock is stolen, the record lands, and no lock is left" \
  "[ ! -e \"\$L2\" ] && [ ! -e \"\$L2.steal\" ] && jq -se 'length==1 and .[0].command==\"cmd 2\"' \"\$SD/s1.failures.jsonl\" >/dev/null 2>&1"

echo
echo "SCRIPT-TESTS: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
