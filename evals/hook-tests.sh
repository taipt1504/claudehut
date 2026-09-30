#!/usr/bin/env bash
# hook-tests.sh — the v0.12 advisory hook contract + state schema 2 (05-hooks.md §11, 04 §9, 10 M1).
# Replaces gate-tests.sh: the deny/block gates it tested are gone; the still-relevant parts (state-writer
# lock, set-review evidence, set-plan smart gate, cost-report) are folded in below against schema 2.
#
# Every hook run goes through run_hook, which asserts the contract on EVERY invocation — exit 0, at most one
# JSON object on stdout, valid JSON — and appends stdout to one corpus that AC7 greps at the end for
# decision / permissionDecision / updatedInput / continue. Silence is also asserted positively: non-fault
# cases must leave state/hook-errors.log empty, so a hook that fails silently cannot pass as "silent".
#
# Run: evals/hook-tests.sh --fast     contract + behavior only (deterministic, no Claude, no timing)
#      evals/hook-tests.sh            --fast, then the regression suites evals/regress/state-tests.sh,
#                                     script-tests.sh, doclint-tests.sh and review-pack-tests.sh (mutants off; their
#                                     counts are added; a missing one fails)
# Latency (AC12) is NOT gated here: wall-clock time depends on the machine and its load. It is the benchmark
# evals/hook-bench.sh (a report; HOOK_BENCH_STRICT=1 gates it).
set -uo pipefail
FAST=0
case "${1:-}" in --fast) FAST=1 ;; "") ;; *) echo "usage: $0 [--fast]" >&2; exit 2 ;; esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export CLAUDE_PLUGIN_ROOT="$ROOT"
unset CLAUDE_ENV_FILE CLAUDEHUT_SESSION_ID CLAUDEHUT_HUB CLAUDEHUT_DEBUG_PAYLOAD CLAUDEHUT_FEDERATION_ROOT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; }
chk() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
CORPUS="$W/corpus.out"; : > "$CORPUS"
ST="$ROOT/bin/claudehut-state"
FX="$ROOT/evals/hook-fixtures"
HOOKS="bootstrap maintain inject-phase advise-write record-agent-dispatch format-java lint-reuse doclint-advise record-failure record-dispatch verify-subagent record-rules-loaded"

# run_hook <script> <project-dir> <payload> [VAR=value …] → OUT, RC; contract asserted on every call.
N_RUNS=0; N_CONTRACT_BAD=0
run_hook() {
  local s="$1" p="$2" pl="$3"; shift 3
  OUT="$(printf '%s' "$pl" | env CLAUDE_PROJECT_DIR="$p" "$@" bash "$ROOT/scripts/$s.sh" 2>/dev/null)"; RC=$?
  N_RUNS=$((N_RUNS+1))
  printf '%s\n' "$OUT" >> "$CORPUS"
  if [ "$RC" -ne 0 ] || ! printf '%s' "$OUT" | jq -se 'length<=1 and all(.[]; type=="object")' >/dev/null 2>&1; then
    N_CONTRACT_BAD=$((N_CONTRACT_BAD+1)); bad "contract: $s rc=$RC stdout=$(printf '%s' "$OUT" | head -c 160)"
  fi
}
silent()   { [ -z "$OUT" ]; }
one_ctx()  { printf '%s' "$OUT" | jq -e --arg e "$1" 'keys==["hookSpecificOutput"] and (.hookSpecificOutput|keys|sort)==["additionalContext","hookEventName"] and .hookSpecificOutput.hookEventName==$e' >/dev/null 2>&1; }
ctx()      { printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null; }
errlog_empty() { [ ! -s "$1/.claude/claudehut/state/hook-errors.log" ]; }

new_plane() { # $1 = dir name → prints project path with an empty plane
  local p="$W/$1"; mkdir -p "$p/.claude/claudehut"; printf '%s' "$p"
}
mk_task() { # $1 project  $2 sid  $3 id  $4 route  $5 plan_approved  [$6 extra jq]
  local P="$1/.claude/claudehut"
  mkdir -p "$P/state" "$P/tasks/$3"
  printf '{"schema":2,"active_task":"%s"}\n' "$3" > "$P/state/$2.json"
  jq -nc --arg id "$3" --arg r "$4" --argjson a "$5" '{schema:2,id:$id,route:$r,profile:null,phase:"implement",
    plan_approved:$a,review:"pending",plan_review_round:0,base:{},pre_dirty:{},scope:["src/main/*","*/src/main/*"],
    enforcement_set:[],status:"active"}' | jq -c "${6:-.}" > "$P/tasks/$3/task.json"
}
wpl() { jq -nc --arg s "$1" --arg f "$2" --arg t "${3:-Write}" '{session_id:$s,hook_event_name:"PreToolUse",tool_name:$t,tool_input:{file_path:$f}}'; }
fsum() { find "$1" -type f ! -name hook-errors.log ! -name '*.nudged' ! -name '*.nudged.*' -exec shasum {} + 2>/dev/null | sort | shasum | awk '{print $1}'; }

# v0.12 M3: set-spec/set-plan/set-plan-review run doclint, so fixtures are the templates' own filled-in examples.
exa() { sed -n "/^# $2/,\$p" "$ROOT/skills/$1"; }   # the example, from its "# Kind:" line down
EXSPEC="$(exa write-spec/references/spec-template.md Spec:)"
EXPLAN="$(exa write-plan/references/plan-template.md Plan:)"
EXPR="$(exa write-plan/references/plan-review-template.md 'Plan review')"
[ -n "$EXSPEC" ] && [ -n "$EXPLAN" ] && [ -n "$EXPR" ] || bad "fixtures: a template example came out empty (its '# Kind' heading moved)"

payload_for() { # $1 hook → a representative payload for session S
  case "$1" in
    bootstrap|maintain) echo '{"session_id":"S","source":"startup","hook_event_name":"SessionStart"}' ;;
    inject-phase) echo '{"session_id":"S","prompt":"fix the settlement completion bug","hook_event_name":"UserPromptSubmit"}' ;;
    advise-write|format-java|lint-reuse) wpl S "src/main/java/a/Foo.java" ;;
    doclint-advise) jq -nc '{session_id:"S",hook_event_name:"PostToolUse",tool_name:"Write",tool_input:{file_path:".claude/claudehut/tasks/0001-x/spec.md"}}' ;;
    record-agent-dispatch) echo '{"session_id":"S","tool_name":"Agent","tool_use_id":"t1","tool_input":{"subagent_type":"claudehut:claudehut-planner","name":"planner-1"}}' ;;
    record-failure) echo '{"session_id":"S","tool_name":"Bash","tool_input":{"command":"false"},"error":"Exit code 1\nboom","is_interrupt":false}' ;;
    record-dispatch) echo '{"session_id":"S","agent_id":"a1","agent_type":"planner-1","hook_event_name":"SubagentStart"}' ;;
    verify-subagent) echo '{"session_id":"S","agent_id":"a1","agent_type":"planner-1","effort":{"level":"high"},"hook_event_name":"SubagentStop"}' ;;
    record-rules-loaded) echo '{"session_id":"S","file_path":".claude/rules/x.md","load_reason":"session_start"}' ;;
  esac
}

echo "== AC14 surface: scripts, lib, hooks.json wiring =="
for h in $HOOKS; do [ -x "$ROOT/scripts/$h.sh" ] || bad "not executable: scripts/$h.sh"; done
ok "every wired hook script exists and is executable ($(echo $HOOKS | wc -w | tr -d ' ') scripts)"
chk "lib/hook-common.sh and lib/resolve-agent.sh parse" 'bash -n "$ROOT/scripts/lib/hook-common.sh" && bash -n "$ROOT/scripts/lib/resolve-agent.sh"'
chk "hook-common has no set -e / set -u (K1)" '! grep -qE "^[[:space:]]*set -[a-z]*[eu]" "$ROOT/scripts/lib/hook-common.sh"'
chk "no hook script sets -e or -u (K1)" '! grep -lE "^[[:space:]]*set -[a-z]*[eu]" $(for h in $HOOKS; do echo "$ROOT/scripts/$h.sh"; done) >/dev/null'
chk "no hook script or lib can print a decision field (K4, static)" \
  '! grep -nE "permissionDecision|\"decision\"|decision:|updatedInput|\"continue\"|exit 2" $(for h in $HOOKS; do echo "$ROOT/scripts/$h.sh"; done) "$ROOT/scripts/lib/"*.sh | grep -v "^[^:]*:[0-9]*:[[:space:]]*#" | grep -q .'
for gone in gate-done gate-write record-skill record-skill-expansion persist-state; do
  [ ! -e "$ROOT/scripts/$gone.sh" ] || bad "removed script still present: scripts/$gone.sh"
done
ok "gate-done, gate-write, record-skill, record-skill-expansion, persist-state are deleted"
chk "PreToolUse(Agent) record-agent-dispatch is SYNC (timeout 5): its ledger row lands before SubagentStart reads it (HC2-3)" \
  'jq -e "[.hooks.PreToolUse[] | select(.matcher==\"Agent\") | .hooks[] | select(.command|test(\"record-agent-dispatch\"))] | length==1 and all(.[]; (.async // false)==false and .timeout==5)" "$ROOT/hooks/hooks.json" >/dev/null'

echo "== AC1: no plane — every hook exits 0, prints nothing, creates nothing =="
# A stub formatter on PATH, so format-java's half of AC1 does not pass merely because none is installed here.
mkdir -p "$W/fmtbin"; printf '#!/bin/sh\n: > "%s/fmt-ran"\n' "$W" > "$W/fmtbin/google-java-format"; chmod +x "$W/fmtbin/google-java-format"
FMT_PATH="$W/fmtbin:$PATH"
for h in $HOOKS; do
  NP="$W/noplane-$h"; mkdir -p "$NP/src/main/java/a"; printf 'class Foo {}\n' > "$NP/src/main/java/a/Foo.java"
  before="$(find "$NP" | wc -l)"
  run_hook "$h" "$NP" "$(payload_for "$h" | sed "s#src/main#$NP/src/main#")" CLAUDE_ENV_FILE="$W/env-$h" PATH="$FMT_PATH"
  { silent && [ "$(find "$NP" | wc -l)" = "$before" ] && [ ! -e "$NP/.claude" ] && [ ! -s "$W/env-$h" ]; } \
    || bad "AC1: $h without a plane printed or created something"
done
ok "AC1: all $(echo $HOOKS | wc -w | tr -d ' ') hooks silent and file-neutral without a plane"
chk "AC1/K7: format-java never runs an installed formatter in a repo without a plane" '[ ! -e "$W/fmt-ran" ]'

echo "== AC2/AC3/AC4: advise-write predicate =="
P="$(new_plane p-noTask)"
run_hook advise-write "$P" "$(wpl S "$P/src/main/java/a/Foo.java")"
chk "AC2: plane, no task, Write src/main/…/Foo.java → silent" 'silent && errlog_empty "$P"'
chk "AC2 / 04-AC7: a no-task session leaves no state/<sid>.json" '[ ! -e "$P/.claude/claudehut/state/S.json" ]'

P="$(new_plane p-full)"; mk_task "$P" S 0001-x full false
before="$(fsum "$P/.claude/claudehut")"
run_hook advise-write "$P" "$(wpl S "$P/src/main/java/a/Foo.java" Edit)"
chk "AC3: full + plan_approved=false, first in-scope Edit → exactly one object, only additionalContext" 'one_ctx PreToolUse'
chk "AC3: the note names the task and is a fact (no MUST / REQUIRED NEXT)" 'ctx | grep -q "0001-x" && ! ctx | grep -qE "MUST|REQUIRED NEXT"'
chk "AC3: the note is ≤500 chars (K9)" '[ "$(ctx | wc -m | tr -d " ")" -le 501 ]'
run_hook advise-write "$P" "$(wpl S "$P/svc-a/src/main/java/a/Bar.java" Edit)"
chk "AC3: second in-scope Edit (other file, */src/main/*) → silent" 'silent'
chk "K8: state/<sid>.json and task.json unchanged; dedupe lives in state/<sid>.nudged" \
  '[ "$(fsum "$P/.claude/claudehut")" = "$before" ] && grep -qxF "advise-write:0001-x" "$P/.claude/claudehut/state/S.nudged"'
run_hook advise-write "$P" "$(wpl S2 "$P/src/main/java/a/Foo.java")"
chk "a different session without its own pointer is not affected" 'silent'
chk "AC3: no hook error logged on the happy path" 'errlog_empty "$P"'

# Parallel tool calls in one message (and [P] subagents sharing a session) run PreToolUse hooks concurrently.
# The once-per-task claim must be atomic: 8 concurrent in-scope Edits × 10 trials → exactly one note per trial.
dup=""
for trial in 1 2 3 4 5 6 7 8 9 10; do
  P="$(new_plane "p-par$trial")"; mk_task "$P" S 0001-par full false
  for i in 1 2 3 4 5 6 7 8; do
    wpl S "$P/src/main/java/C$i.java" Edit | CLAUDE_PROJECT_DIR="$P" bash "$ROOT/scripts/advise-write.sh" > "$W/par$trial.$i" 2>/dev/null &
  done
  wait
  n="$(cat "$W"/par"$trial".* | grep -c hookSpecificOutput)"
  [ "$n" = 1 ] || dup="$dup trial$trial:$n"
done
chk "AC3: 8 concurrent in-scope Edits × 10 trials → exactly one note per trial (atomic claim)${dup:+ — got$dup}" '[ -z "$dup" ]'

P="$(new_plane p-nb)"; mk_task "$P" S 0001-nb full false
run_hook advise-write "$P" "$(jq -nc --arg f "$P/src/main/nb/x.ipynb" '{session_id:"S",tool_name:"NotebookEdit",tool_input:{notebook_path:$f}}')"
chk "NotebookEdit (notebook_path) is covered by the same predicate" 'one_ctx PreToolUse'

P="$(new_plane p-light)"; mk_task "$P" S 0002-l light false
run_hook advise-write "$P" "$(wpl S "$P/src/main/java/a/Foo.java" Edit)"
chk "AC4: route=light → silent" 'silent'
P="$(new_plane p-approved)"; mk_task "$P" S 0003-a full true
run_hook advise-write "$P" "$(wpl S "$P/src/main/java/a/Foo.java" Edit)"
chk "AC4: full with plan_approved=true → silent" 'silent && errlog_empty "$P"'
P="$(new_plane p-closed)"; mk_task "$P" S 0004-c full false '.status="superseded"'
run_hook advise-write "$P" "$(wpl S "$P/src/main/java/a/Foo.java")"
chk "a superseded task behind a stale pointer is not active → silent" 'silent'
P="$(new_plane p-scope)"; mk_task "$P" S 0005-s full false '.scope=["core/src/main/*"]'
run_hook advise-write "$P" "$(wpl S "$P/src/main/java/a/Foo.java")"
chk "task.scope is honoured: src/main outside a narrowed scope → silent" 'silent'
run_hook advise-write "$P" "$(wpl S "$P/core/src/main/java/a/Foo.java")"
chk "task.scope is honoured: inside the narrowed scope → one note" 'one_ctx PreToolUse'

echo "== AC5: out-of-scope paths inside an active full task stay silent =="
P="$(new_plane p-ac5)"; mk_task "$P" S 0006-o full false
for f in "/private/tmp/claude-501/x/scratchpad/gen.mjs" "$P/.understand-anything/tmp/x.cjs" "$P/build.gradle" \
         "$P/docs/x.md" "$P/.claude/rules/x.md" "$P/src/test/java/a/FooTest.java" "/elsewhere/src/main/X.java" \
         ".claude/claudehut/tasks/0006-o/plan.md"; do
  run_hook advise-write "$P" "$(wpl S "$f")"
  silent || bad "AC5: $f produced output"
done
ok "AC5: scratchpad, .understand-anything/tmp, build.gradle, docs/, .claude/rules, tests, other repos → silent"
run_hook advise-write "$P" "$(wpl S "src/main/java/a/Rel.java")"
chk "AC5: out-of-scope writes did not consume the once-per-task note (relative in-scope path still gets it)" 'one_ctx PreToolUse'
P="$(new_plane p-trav)"; mk_task "$P" S 0007-t full false
run_hook advise-write "$P" "$(wpl S "$P/.claude/claudehut/../../src/main/java/Evil.java")"
chk "a traversal path is judged where it resolves (src/main → in scope)" 'one_ctx PreToolUse'

echo "== AC15: replay core-ledger 2e70d1d8 (343 dirty files) and report-service 652fab55 =="
CLP="$W/core-ledger-ms"; CLJ="$CLP/src/main/java/com/f8a/msn/winx/ledger/service/dynamicva"
mkdir -p "$CLP/.claude/claudehut/state" "$CLP/.claude/claudehut/tasks/0009-dynamic-va-search-trim-whitespace" "$CLJ"
# 342 untracked files + the edit target = the 343 v0.11 counted; the reuse-scan the v0.11 state names exists.
( cd "$CLP" && git init -q && i=0 && while [ $i -lt 342 ]; do printf 'x\n' > "untracked-$i.txt"; i=$((i+1)); done )
printf 'class DynamicVaSearchRepository {}\n' > "$CLJ/DynamicVaSearchRepository.java"
printf '| Dimension | Existing asset | Decision | Fit | Impact | Effort |\n' > "$CLP/.claude/claudehut/tasks/0009-dynamic-va-search-trim-whitespace/reuse-scan.md"
cp "$FX/core-ledger-2e70d1d8.state.json" "$CLP/.claude/claudehut/state/2e70d1d8-b74b-4887-ba36-2510d62d3a04.json"
CL_PAY="$(sed "s#__PROJECT__#$CLP#g" "$FX/core-ledger-2e70d1d8.edit.json")"
chk "replay fixture is faithful: the working tree really holds 343 dirty files" \
  '[ "$(cd "$CLP" && git status --porcelain --untracked-files=all | grep -vc "^?? \.claude/")" = 343 ]'
# Control: the v0.11 gate (vendored verbatim from 2c0b93b, not executable, run only here) must DENY the same
# payloads — otherwise "v0.12 is silent" could just mean the fixture no longer reproduces the incident.
V011="$FX/v011-gate-write.sh.txt"
v011="$(printf '%s' "$CL_PAY" | CLAUDE_PROJECT_DIR="$CLP" bash "$V011" 2>/dev/null)"
chk "replay control: v0.11 gate-write.sh DENIES this payload ('touches 343 files')" \
  'printf "%s" "$v011" | jq -e ".hookSpecificOutput.permissionDecision==\"deny\" and (.hookSpecificOutput.permissionDecisionReason|test(\"343 files\"))" >/dev/null'
run_hook advise-write "$CLP" "$CL_PAY"
chk "AC15: core-ledger 2e70d1d8 Edit with v0.11 state → stdout empty, exit 0" 'silent'
mk_task "$CLP" 2e70d1d8-b74b-4887-ba36-2510d62d3a04 0009-dva full false
run_hook advise-write "$CLP" "$CL_PAY"
chk "AC15 control: the same Edit under a schema-2 full unapproved task DOES get the note (not vacuous)" 'one_ctx PreToolUse'

RS="$W/report-service-ms"; mkdir -p "$RS/.claude/claudehut/state" "$RS/.understand-anything/tmp"
cp "$FX/report-service-652fab55.state.json" "$RS/.claude/claudehut/state/652fab55-9de3-4336-8cdf-51718ba9508f.json"
for k in scratchpad ua; do
  RP="$(sed "s#__PROJECT__#$RS#g" "$FX/report-service-652fab55.$k.json")"
  o="$(printf '%s' "$RP" | CLAUDE_PROJECT_DIR="$RS" bash "$V011" 2>/dev/null)"
  printf '%s' "$o" | jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null 2>&1 \
    && ok "replay control: v0.11 denied report-service $k write" || bad "replay control: v0.11 did not deny $k (fixture unfaithful)"
  run_hook advise-write "$RS" "$RP"
  silent && ok "AC15: report-service 652fab55 $k write (v0.11 armed state) → stdout empty" || bad "AC15: report-service $k produced output"
done
mk_task "$RS" 652fab55-9de3-4336-8cdf-51718ba9508f 0010-r full false
for k in scratchpad ua; do
  run_hook advise-write "$RS" "$(sed "s#__PROJECT__#$RS#g" "$FX/report-service-652fab55.$k.json")"
  silent || bad "AC15: $k with an active full task produced output"
done
ok "AC15: report-service scratchpad + .understand-anything writes stay silent even inside an active full task"
chk "AC15: no hook error logged by the replays" 'errlog_empty "$CLP" && errlog_empty "$RS"'

echo "== AC6: fault injection — every hook × {corrupt state, corrupt task, legacy bypass, broken jq, garbage jq, no jq, bad stdin, no lib} =="
FB="$W/fakebin-fail"; mkdir -p "$FB"; printf '#!/bin/sh\nexit 1\n' > "$FB/jq"; chmod +x "$FB/jq"
NJ="$W/nojq-bin"; mkdir -p "$NJ"; ln -s "$(command -v bash)" "$NJ/bash"; ln -s "$(command -v cat)" "$NJ/cat"   # no jq, on any OS
FG="$W/fakebin-garbage"; mkdir -p "$FG"; printf '#!/bin/sh\ncat >/dev/null 2>&1; echo "{garbage"; echo "}{\\"decision\\":\\"block\\"}"\n' > "$FG/jq"; chmod +x "$FG/jq"
fault_setup() { # $1 kind → project dir
  local p; p="$(new_plane "fault-$1-$2")"; mkdir -p "$p/src/main/java/a"; printf 'class Foo { static boolean isBlank(String s){return s==null;} }\n' > "$p/src/main/java/a/Foo.java"
  case "$1" in
    corrupt-state) mkdir -p "$p/.claude/claudehut/state"; printf '{not json' > "$p/.claude/claudehut/state/S.json" ;;
    corrupt-task)  mk_task "$p" S 0001-f full false; printf '{"schema":2,' > "$p/.claude/claudehut/tasks/0001-f/task.json" ;;
    legacy-bypass) mkdir -p "$p/.claude/claudehut/state"; printf '{"session":"S","phase":"implement","bypass":true,"complexity":"full"}\n' > "$p/.claude/claudehut/state/S.json" ;;
    *)             mk_task "$p" S 0001-f full false ;;
  esac
  printf '%s' "$p"
}
for kind in corrupt-state corrupt-task legacy-bypass jq-fail jq-garbage no-jq bad-stdin empty-stdin; do
  for h in $HOOKS; do
    p="$(fault_setup "$kind" "$h")"; pl="$(payload_for "$h" | sed "s#src/main#$p/src/main#")"
    case "$kind" in
      jq-fail)     run_hook "$h" "$p" "$pl" PATH="$FB:$PATH" ;;
      jq-garbage)  run_hook "$h" "$p" "$pl" PATH="$FG:$PATH" ;;
      no-jq)       run_hook "$h" "$p" "$pl" PATH="$NJ" ;;
      bad-stdin)   run_hook "$h" "$p" 'this is not json {' ;;
      empty-stdin) run_hook "$h" "$p" '' ;;
      *)           run_hook "$h" "$p" "$pl" ;;
    esac
    case "$kind:$h" in
      corrupt-state:advise-write|corrupt-task:advise-write|legacy-bypass:advise-write|legacy-bypass:lint-reuse|corrupt-state:lint-reuse)
        silent || bad "AC6: $kind → $h should treat the session as task-free but printed output" ;;
    esac
  done
done
ok "AC6: 8 fault kinds × $(echo $HOOKS | wc -w | tr -d ' ') hooks: every run exit 0 with ≤1 valid JSON object (asserted per run)"
p="$(fault_setup corrupt-state log)"; run_hook advise-write "$p" "$(wpl S "$p/src/main/java/a/Foo.java")"
chk "K3: a corrupt state file is logged to state/hook-errors.log (≤300 B/line), never surfaced" \
  '[ -s "$p/.claude/claudehut/state/hook-errors.log" ] && [ "$(awk "length>300" "$p/.claude/claudehut/state/hook-errors.log" | wc -l | tr -d " ")" = 0 ]'
p="$(new_plane nostate)"   # a plane with no state/ dir at all
run_hook bootstrap "$p" '{"session_id":"S","source":"startup"}'
chk "a plane without state/ still bootstraps (state/ created, one object)" 'one_ctx SessionStart && [ -d "$p/.claude/claudehut/state" ]'
mkdir -p "$W/nolib/scripts"; cp "$ROOT/scripts/advise-write.sh" "$W/nolib/scripts/"
p="$(new_plane nolib-p)"; mk_task "$p" S 0001-n full false
# here-string, not a pipe: the hook exits before reading stdin, and under pipefail the writer's SIGPIPE (141)
# would be reported as the hook's exit code.
o="$(CLAUDE_PROJECT_DIR="$p" bash "$W/nolib/scripts/advise-write.sh" 2>/dev/null <<<"$(wpl S "$p/src/main/A.java")")"; r=$?
chk "a missing lib/hook-common.sh → exit 0, silent" '[ "$r" = 0 ] && [ -z "$o" ]'
p="$(new_plane ub)"; mk_task "$p" S 0001-u full false
o="$(wpl S "$p/src/main/A.java" | CLAUDE_PROJECT_DIR="$p" bash -c 'set -u; . "$0"' "$ROOT/scripts/advise-write.sh" 2>/dev/null)"; r=$?
chk "unbound variable under an inherited set -u → trapped: exit 0, ≤1 JSON" '[ "$r" = 0 ] && printf "%s" "$o" | jq -se "length<=1" >/dev/null'

echo "== AC8/AC9: inject-phase — machine turns silent, human turns get ≤500 chars of learnings =="
P="$(new_plane ip)"
python3 - "$P" <<'PYX'
import json,sys
with open(sys.argv[1]+'/.claude/claudehut/learnings.jsonl','w') as f:
    for i in range(12):
        f.write(json.dumps({'id':'L-%04d'%i,'category':'pitfall','trigger':'settlement|completion','learning':'settlement completion lesson %d with enough substance to clear the floor and then some more words to be long'%i,'evidence':'S%d.java:1 and a long citation list that goes on and on and on'%i,'confidence':0.8,'hits':3,'ts':'2026-08-15T00:00:00Z'})+'\n')
PYX
for pr in '<teammate-message teammate_id="x">settlement completion</teammate-message>' '<\teammate-message>settlement' \
          '<agent-message from="a">settlement completion</agent-message>' '<\agent-message>settlement completion' \
          '<task-notification><status>completed</status> settlement</task-notification>' '<\task-notification>settlement' \
          'Another Claude session sent a message: settlement completion' $'  \n <task-notification>settlement completion'; do
  run_hook inject-phase "$P" "$(jq -nc --arg p "$pr" '{session_id:"M",prompt:$p}')"
  silent || bad "AC8: machine prompt injected: ${pr:0:40}"
done
ok "AC8: 8 machine-generated prefixes (teammate/agent/task-notification, escaped and not, leading space, cross-session) → silent"
chk "AC8: machine turns did not grow the injected-ids set" '[ ! -e "$P/.claude/claudehut/state/M.injected.json" ]'
run_hook inject-phase "$P" '{"session_id":"H","prompt":"fix the settlement completion bug"}'
chk "human prompt with matching learnings → one object with a learnings block" 'one_ctx UserPromptSubmit && ctx | grep -q "settlement completion lesson"'
chk "the learnings block is ≤500 chars and keeps its closing untrusted marker" '[ "$(ctx | wc -m | tr -d " ")" -le 501 ] && ctx | grep -q "^<</CLAUDEHUT_UNTRUSTED_"'
chk "AC9: no Untriaged / Phase 0 / phase line on a no-task human prompt" '! ctx | grep -qiE "untriaged|phase 0|phase:"'
first="$(ctx)"; run_hook inject-phase "$P" '{"session_id":"H","prompt":"fix the settlement completion bug"}'
chk "LRN-9: the next prompt does not re-pay for the same entries (exclude set accumulates)" '[ "$(ctx)" != "$first" ] && [ "$(jq length "$P/.claude/claudehut/state/H.injected.json")" -ge 4 ]'
P2="$(new_plane ip-empty)"; run_hook inject-phase "$P2" '{"session_id":"H","prompt":"what does this service do?"}'
chk "AC9: plane without learnings, human question → silent (nothing to say)" 'silent && errlog_empty "$P2"'

echo "== bootstrap / maintain =="
P="$(new_plane bs)"; FAKE="$W/fakeclaude"; mkdir -p "$FAKE"; printf '#!/bin/sh\ntouch "%s/claude-called"\necho "[]"\n' "$W" > "$FAKE/claude"; chmod +x "$FAKE/claude"
: > "$W/envfile"
run_hook bootstrap "$P" '{"session_id":"sid-abc","source":"startup"}' CLAUDE_ENV_FILE="$W/envfile" PATH="$FAKE:$PATH"
chk "bootstrap: exactly one SessionStart object" 'one_ctx SessionStart'
chk "bootstrap: 'Session id: <sid>' fallback line (B7)" 'ctx | grep -qx "Session id: sid-abc"'
chk "bootstrap: CLAUDE_ENV_FILE gets export CLAUDEHUT_SESSION_ID=<sid> (P1)" 'grep -qx "export CLAUDEHUT_SESSION_ID=sid-abc" "$W/envfile"'
chk "bootstrap: no state armed — no state/<sid>.json (A9, B2)" '[ ! -e "$P/.claude/claudehut/state/sid-abc.json" ]'
chk "bootstrap: never spawns claude plugin list (B10)" '[ ! -e "$W/claude-called" ]'
chk "bootstrap: no MUST / MANDATORY / REQUIRED NEXT in lines bootstrap itself adds (F-2)" \
  '! ctx | sed -n "/^State CLI:/,\$p" | grep -qE "MUST|MANDATORY|REQUIRED NEXT"'
chk "bootstrap: the digest is the first block" '[ "$(ctx | head -1)" = "$(head -1 "$ROOT/skills/claudehut-workflow/references/digest.md")" ]'
mk_task "$P" sid-abc 0042-fix-ilike light false '.phase="implement"'
run_hook bootstrap "$P" '{"session_id":"sid-abc","source":"resume"}'
chk "bootstrap: an open task adds 'Task đang mở: <id> (<route>, phase <p>)'" 'ctx | grep -qx "Task đang mở: 0042-fix-ilike (light, phase implement)"'
cp "$FX/report-service-652fab55.state.json" "$P/.claude/claudehut/state/legacy.json"
run_hook bootstrap "$P" '{"session_id":"legacy","source":"startup"}'
chk "bootstrap: a v0.11 state file is no task (no task line)" '! ctx | grep -q "Task đang mở"'
mkdir -p "$P/.understand-anything" "$P/.claude/summer-kb"; echo '{}' > "$P/.understand-anything/knowledge-graph.json"
echo '{"summerCommit":"abcdef1234","includedModules":["summer-core","summer-kafka"]}' > "$P/.claude/summer-kb/.summer-kb-meta.json"
run_hook bootstrap "$P" '{"session_id":"x","source":"startup"}'
chk "bootstrap: graph and Summer KB are stated as facts (path, modules, commit)" \
  'ctx | grep -q "^understand-anything graph: .understand-anything/knowledge-graph.json" && ctx | grep -q "modules summer-core,summer-kafka; summerCommit abcdef1"'
chk "bootstrap: no hook error logged" 'errlog_empty "$P"'
# D5 (v0.12 M2): the explorer's graph query, taken verbatim from its prompt, must survive nodes without
# name or summary. A bare .name+... throws on the first nameless node and the explorer loses every lead.
EXQ="$(sed -n '/jq -r --arg t "settlement"/,/@tsv. "\$G"/p' "$ROOT/agents/claudehut-explorer.md" | tr '\n' ' ' | sed -E "s/^[^']*'//; s/'[^']*\$//")"
printf '%s' '{"nodes":[{"id":"n1","type":"file"},{"id":"n2","type":"class","name":"Settlement"},{"id":"n3","type":"class","name":"PayoutJob","summary":"runs the settlement batch","filePath":"a/B.java"}],"edges":[]}' > "$W/kg-nameless.json"
chk "explorer: graph query tolerates a nameless node and a node without summary (D5)" \
  'case "$EXQ" in *ascii_downcase*) :;; *) false;; esac && out="$(jq -r --arg t settlement "$EXQ" "$W/kg-nameless.json")" && [ "$(printf "%s\n" "$out" | cut -f1 | tr "\n" " ")" = "n2 n3 " ]'

P="$(new_plane mt)"; S_="$P/.claude/claudehut/state"; mkdir -p "$S_"
( cd "$S_" && touch -t 202607010000 old.failures.jsonl old.nudged old.nudged.advise-write_0001-x old.json CUR.failures.jsonl && touch fresh.nudged )
head -c 70000 /dev/zero | tr '\0' 'e' > "$S_/hook-errors.log"
printf '%s' "$(jq -r .version "$ROOT/.claude-plugin/plugin.json")" > "$P/.claude/claudehut/.plugin-version"
run_hook maintain "$P" '{"session_id":"CUR","source":"startup"}'
chk "maintain: sweeps sidecars and v0.11 state older than 7 days" '[ ! -e "$S_/old.failures.jsonl" ] && [ ! -e "$S_/old.nudged" ] && [ ! -e "$S_/old.nudged.advise-write_0001-x" ] && [ ! -e "$S_/old.json" ]'
chk "maintain: never sweeps the current session's files or fresh ones" '[ -e "$S_/CUR.failures.jsonl" ] && [ -e "$S_/fresh.nudged" ]'
chk "maintain: rotates hook-errors.log past 64 KB" '[ "$(wc -c < "$S_/hook-errors.log" | tr -d " ")" -le 40000 ]'
P="$(new_plane mt3)"; S_="$P/.claude/claudehut/state"; mkdir -p "$S_" "$P/.claude/claudehut/tasks/0001-open" "$P/.claude/claudehut/tasks/0002-shut"
printf '{"schema":2,"status":"active"}\n' > "$P/.claude/claudehut/tasks/0001-open/task.json"
printf '{"schema":2,"status":"done"}\n' > "$P/.claude/claudehut/tasks/0002-shut/task.json"
printf '{"schema":2,"active_task":"0001-open"}\n' > "$S_/longrun.json"; printf '{"schema":2,"active_task":"0002-shut"}\n' > "$S_/closed.json"
printf '{"schema":2,"active_task":null}\n' > "$S_/idle.json"; printf '{"file":"x"}\n' > "$S_/0001-open.suspects.jsonl"; printf '{"file":"x"}\n' > "$S_/0002-shut.suspects.jsonl"
( cd "$S_" && touch -t 202607010000 longrun.json closed.json idle.json 0001-open.suspects.jsonl 0002-shut.suspects.jsonl )
run_hook maintain "$P" '{"session_id":"other","source":"startup"}'
chk "maintain: an old pointer that still names an active task survives the sweep (R2-2, V2-6)" '[ -e "$S_/longrun.json" ]'
chk "maintain: old pointers to a closed task or to no task are swept" '[ ! -e "$S_/closed.json" ] && [ ! -e "$S_/idle.json" ]'
chk "maintain: an active task's suspects survive; a closed task's are swept" '[ -e "$S_/0001-open.suspects.jsonl" ] && [ ! -e "$S_/0002-shut.suspects.jsonl" ]'
FR="$W/fake root"; mkdir -p "$FR/skills/summer-kb-setup/scripts"
printf 'import sys, pathlib\npathlib.Path(sys.argv[1], "KB_INSTALLED").touch()\n' > "$FR/skills/summer-kb-setup/scripts/install_summer_kb.py"
P="$W/with space/proj"; mkdir -p "$P/.claude/claudehut" "$P/svc"; printf "dependencies { implementation 'io.f8a.summer:summer-core:1.0' }\n" > "$P/svc/build.gradle"
run_hook maintain "$P" '{"session_id":"CUR","source":"startup"}' CLAUDE_PLUGIN_ROOT="$FR"
chk "maintain: Summer KB detection works under a project path with a space (R2-3)" '[ -e "$P/KB_INSTALLED" ] && errlog_empty "$P"'
P="$(new_plane mt2)"
run_hook maintain "$P" '{"session_id":"CUR","source":"startup"}'
chk "maintain: stamps .plugin-version after refreshing rules (idempotent marker last)" '[ "$(cat "$P/.claude/claudehut/.plugin-version")" = "$(jq -r .version "$ROOT/.claude-plugin/plugin.json")" ]'

echo "== AC10 / 04-AC9: teammate identity (record-agent-dispatch → resolve-agent → SubagentStart/Stop) =="
P="$(new_plane ta)"; L="$P/.claude/claudehut/ledger/dispatches.jsonl"
run_hook record-agent-dispatch "$P" '{"session_id":"S","tool_name":"Agent","tool_use_id":"toolu_1","tool_input":{"subagent_type":"claudehut:claudehut-planner","name":"planner-0099","prompt":"x"}}'
chk "PreToolUse(Agent) is silent and records name + subagent_type + tool_use_id" \
  'silent && jq -e ".name==\"planner-0099\" and .subagent_type==\"claudehut:claudehut-planner\" and .tool_use_id==\"toolu_1\"" "$P/.claude/claudehut/state/S.agent-dispatch.jsonl" >/dev/null'
run_hook record-agent-dispatch "$P" '{"session_id":"S","tool_name":"Bash","tool_input":{"command":"ls"}}'
chk "a payload with no subagent_type records nothing" '[ "$(grep -c "" "$P/.claude/claudehut/state/S.agent-dispatch.jsonl")" = 1 ]'
run_hook verify-subagent "$P" '{"session_id":"S","agent_id":"a1","agent_type":"planner-0099","effort":{"level":"high"}}'
chk "AC10: SubagentStop for a teammate → silent; ledger resolved_type=claudehut:claudehut-planner, teammate=true" \
  'silent && tail -1 "$L" | jq -e ".event==\"stop\" and .agent_type==\"planner-0099\" and .resolved_type==\"claudehut:claudehut-planner\" and .teammate==true and .effort==\"high\"" >/dev/null'
n0="$(grep -c "" "$L")"
run_hook verify-subagent "$P" '{"session_id":"S","agent_id":"a2","agent_type":""}'
chk "AC10: SubagentStop with empty agent_type → silent, no ledger row" 'silent && [ "$(grep -c "" "$L")" = "$n0" ]'
run_hook verify-subagent "$P" '{"session_id":"S","agent_id":"a3","agent_type":"claudehut:claudehut-reviewer"}'
chk "a plugin-scoped agent_type is kept as is (teammate=false)" 'tail -1 "$L" | jq -e ".resolved_type==\"claudehut:claudehut-reviewer\" and .teammate==false" >/dev/null'
run_hook verify-subagent "$P" '{"session_id":"S","agent_id":"a4","agent_type":"Explore"}'
chk "an unknown name is kept unchanged" 'tail -1 "$L" | jq -e ".resolved_type==\"Explore\" and .teammate==false" >/dev/null'
chk "SubagentStop no longer blocks a planner that wrote no plan (ledger only, ADR-H5)" '! grep -q "decision" "$CORPUS"'
run_hook record-agent-dispatch "$P" '{"session_id":"S","tool_name":"Agent","tool_use_id":"toolu_2","tool_input":{"subagent_type":"claudehut:claudehut-implementer","name":"impl-1"}}'
run_hook record-dispatch "$P" '{"session_id":"S","agent_id":"b1","agent_type":"impl-1"}'
chk "SubagentStart: an implementer TEAMMATE gets one line pointing at skills/implement/SKILL.md" 'one_ctx SubagentStart && ctx | grep -q "skills/implement/SKILL.md"'
chk "SubagentStart: start row carries resolved_type + teammate" 'tail -1 "$L" | jq -e ".event==\"start\" and .resolved_type==\"claudehut:claudehut-implementer\" and .teammate==true" >/dev/null'
run_hook record-dispatch "$P" '{"session_id":"S","agent_id":"b2","agent_type":"claudehut:claudehut-implementer"}'
chk "SubagentStart: a regular (non-teammate) implementer → silent" 'silent'
run_hook record-dispatch "$P" '{"session_id":"S","agent_id":"b3","agent_type":"planner-0099"}'
chk "SubagentStart: a planner teammate → silent (only the implementer needs the pointer)" 'silent && errlog_empty "$P"'

# V3-C2: a field of another JSON type (number, object) must not throw in the jq slice and drop the whole row.
P="$(new_plane tn)"; L="$P/.claude/claudehut/ledger/dispatches.jsonl"
run_hook record-agent-dispatch "$P" '{"session_id":"S","tool_name":"Agent","tool_use_id":9,"tool_input":{"subagent_type":5,"name":6}}'
run_hook record-dispatch "$P" '{"session_id":"S","agent_id":7,"agent_type":"planner-1","cwd":{"p":1}}'
run_hook verify-subagent "$P" '{"session_id":"S","agent_id":7,"agent_type":"planner-1","effort":{"level":3},"agent_transcript_path":8}'
chk "non-string fields (numeric agent_id / effort.level / subagent_type / tool_use_id, object cwd) still write their rows, nothing logged (V3-C2)" \
  'jq -e ".subagent_type==\"5\" and .name==\"6\" and .tool_use_id==\"9\"" "$P/.claude/claudehut/state/S.agent-dispatch.jsonl" >/dev/null && jq -se "length==2 and .[0].event==\"start\" and .[0].agent_id==\"7\" and (.[0].cwd|test(\"p\")) and .[1].event==\"stop\" and .[1].agent_id==\"7\" and .[1].effort==\"3\" and .[1].agent_transcript_path==\"8\"" "$L" >/dev/null && errlog_empty "$P"'

echo "== P-task / P-plane recorders =="
P="$(new_plane lr)"; mkdir -p "$P/src/main/java/a" "$P/tools"
printf 'class U { static boolean isBlank(String s){return s==null;} }\n' > "$P/src/main/java/a/U.java"; cp "$P/src/main/java/a/U.java" "$P/tools/U.java"
run_hook lint-reuse "$P" "$(wpl S "$P/src/main/java/a/U.java")"
chk "lint-reuse: no task → no suspects (P-task)" '[ -z "$(ls "$P/.claude/claudehut/state/"*.suspects.jsonl 2>/dev/null)" ]'
mk_task "$P" S 0001-lr full false
run_hook lint-reuse "$P" "$(wpl S "$P/tools/U.java")"
chk "lint-reuse: active task, path outside scope → no suspects" '[ -z "$(ls "$P/.claude/claudehut/state/"*.suspects.jsonl 2>/dev/null)" ]'
run_hook lint-reuse "$P" "$(wpl S "$P/src/main/java/a/U.java")"
chk "lint-reuse: active task, in scope → reinvented-stdlib suspect staged, silent" 'silent && grep -q reinvented-stdlib "$P/.claude/claudehut/state/0001-lr.suspects.jsonl"'
run_hook record-failure "$P" "$(payload_for record-failure)"
chk "record-failure: records with a plane" 'jq -e ".exit==\"1\"" "$P/.claude/claudehut/state/S.failures.jsonl" >/dev/null'
run_hook record-rules-loaded "$P" "$(payload_for record-rules-loaded)"
chk "record-rules-loaded: records with a plane" 'jq -e ".load_reason==\"session_start\"" "$P/.claude/claudehut/state/S.rules-loaded.jsonl" >/dev/null'
run_hook format-java "$P" "$(wpl S "$P/src/main/java/a/U.java")"
chk "format-java: silent, exit 0" 'silent'
mkdir -p "$P/src/main/java/a"; printf 'class U {}\n' > "$P/src/main/java/a/U.java"; rm -f "$W/fmt-ran"
run_hook format-java "$P" "$(wpl S "$P/src/main/java/a/U.java")" PATH="$FMT_PATH"
chk "format-java: with a plane and a formatter on PATH, the formatter runs (silently)" 'silent && [ -e "$W/fmt-ran" ]'
mkdir -p "$W/other"; printf 'class O {}\n' > "$W/other/O.java"; rm -f "$W/fmt-ran"
run_hook format-java "$P" "$(wpl S "$W/other/O.java")" PATH="$FMT_PATH"
chk "format-java: a .java outside the project is never formatted (R2-5)" 'silent && [ ! -e "$W/fmt-ran" ]'

# V3-C3: the "also declared in" list strips the project prefix literally, whatever the path holds ('#', '&', '.*').
lr_bad=""
for nm in 'p lr #1' 'p lr &.*'; do
  P="$W/$nm"; mkdir -p "$P/.claude/claudehut" "$P/src/main/java/a"
  printf 'class A { static int helperX(int a){return a;} }\n' > "$P/src/main/java/a/A.java"; printf 'class B { static int helperX(int a){return a;} }\n' > "$P/src/main/java/a/B.java"
  mk_task "$P" S 0001-lr light false
  run_hook lint-reuse "$P" "$(wpl S "$P/src/main/java/a/A.java")"
  jq -e 'select(.kind=="duplicate") | .detail | test("also declared in: src/main/java/a/B\\.java —")' "$P/.claude/claudehut/state/0001-lr.suspects.jsonl" >/dev/null 2>&1 && errlog_empty "$P" || lr_bad="$lr_bad [$nm]"
done
chk "lint-reuse: 'also declared in' is project-relative for a project path with '#' or '&.*' (V3-C3)${lr_bad:+ — wrong for:$lr_bad}" '[ -z "$lr_bad" ]'

echo "== claudehut-state schema 2 (04 §3, §9) =="
P="$(new_plane cli)"; ( cd "$P" && git init -q && printf 'n\n' > docs-notes.md && git add -A && git -c user.email=t@t -c user.name=t commit -qm i && printf 'm\n' >> docs-notes.md )
cs() { CLAUDE_PROJECT_DIR="$P" "$ST" "$@"; }
CLAUDEHUT_SESSION_ID=S cs set-phase plan 2>"$W/n.err"; r=$?
chk "no task: set-phase is a notice + exit 0 and writes nothing (04-AC7)" '[ "$r" = 0 ] && grep -q "no active task" "$W/n.err" && [ ! -e "$P/.claude/claudehut/state/S.json" ]'
cs --session S status > "$W/st.json"
chk "status: read-only one-line JSON, active_task null, no state file created" 'jq -e ".active_task==null and .task==null" "$W/st.json" >/dev/null && [ "$(wc -l < "$W/st.json" | tr -d " ")" = 1 ] && [ ! -e "$P/.claude/claudehut/state/S.json" ]'
chk "start requires --slug and --route (A6, B4)" '! cs --session S start --route full 2>/dev/null && ! cs --session S start --slug x 2>/dev/null && ! cs --session S start --route direct --slug x 2>/dev/null'
SO="$(cs --session S start --route light --slug "Fix ILIKE" --profile bugfix 2>/dev/null)"; id1="$(head -1 <<<"$SO")"
T1="$P/.claude/claudehut/tasks/$id1/task.json"
chk "start prints the task id (line 1) and the task dir it created (line 2)" \
  '[ "$(sed -n 2p <<<"$SO")" = ".claude/claudehut/tasks/0001-fix-ilike/" ] && [ "$(wc -l <<<"$SO" | tr -d " ")" = 2 ] && [ -f "$P/$(sed -n 2p <<<"$SO")task.json" ]'
chk "start: tasks/0001-fix-ilike/task.json schema 2 with the documented fields" \
  '[ "$id1" = 0001-fix-ilike ] && jq -e ".schema==2 and .route==\"light\" and .profile==\"bugfix\" and .plan_approved==false and .review==\"pending\" and .plan_review_round==0 and .scope==[\"src/main/*\",\"*/src/main/*\"] and .enforcement_set==[] and .status==\"active\"" "$T1" >/dev/null'
chk "start: base{repo:sha} and pre_dirty{repo:[files]} are captured per repo, '.' = the project (ADR-H6)" \
  'jq -e ".base[\".\"]|test(\"^[0-9a-f]{7,}\$\")" "$T1" >/dev/null && jq -e ".pre_dirty[\".\"]==[\"docs-notes.md\"]" "$T1" >/dev/null'
chk "start: state/<sid>.json is only a pointer" 'jq -e ". == {schema:2, active_task:\"0001-fix-ilike\"}" "$P/.claude/claudehut/state/S.json" >/dev/null'
mkdir -p "$P/.claude/claudehut/tasks/$id1"
printf '%s\n' "$EXSPEC" | sed 's/profile: feature · route: full/profile: bugfix · route: light/' > "$P/.claude/claudehut/tasks/$id1/spec.md"
cs --session S set-spec ".claude/claudehut/tasks/$id1/spec.md" 2>/dev/null
cs --session S set-enforcement --skills claudehut:implement --rules framework/jpa.md 2>/dev/null
chk "set-* write into task.json (spec_path, enforcement_set as one list)" 'jq -e ".spec_path|test(\"spec.md\")" "$T1" >/dev/null && jq -e ".enforcement_set==[\"claudehut:implement\",\"framework/jpa.md\"]" "$T1" >/dev/null'
id2="$(cs --session S start --route full --slug y 2>/dev/null | head -1)"; T2="$P/.claude/claudehut/tasks/$id2/task.json"
chk "04-AC5: start while a task is open → the old task becomes superseded" 'jq -e ".status==\"superseded\" and .superseded_by==\"0002-y\"" "$T1" >/dev/null'
chk "04-AC4: the new task.json carries no field of the previous task (A6, B4)" 'jq -e "has(\"spec_path\")|not" "$T2" >/dev/null && jq -e ".route==\"full\" and .profile==null and .enforcement_set==[]" "$T2" >/dev/null'
h0="$(shasum "$T2" | cut -c1-40)"
for v in "set-bypass true --reason x" "rename x" "mark-skill implement" "pause"; do
  # shellcheck disable=SC2086
  cs --session S $v 2>>"$W/dep.err" || bad "removed verb exited non-zero: $v"
done
chk "removed verbs: exit 0, one-line notice each, no state mutation" '[ "$(shasum "$T2" | cut -c1-40)" = "$h0" ] && [ "$(grep -c "removed in v0.12" "$W/dep.err")" = 4 ]'
# Review reads profile + enforcement_set through status (task.json is the only store): the exact SKILL.md command.
RVCMD="$(grep -o "{ claudehut-state --session \${CLAUDE_SESSION_ID} status[^\`]*" "$ROOT/skills/review/SKILL.md" | head -1)"
rv() { ( cd "$P" && PATH="$ROOT/bin:$PATH" CLAUDE_PROJECT_DIR="$P" CLAUDE_SESSION_ID="$1" bash -c "$RVCMD" ); }
cs --session S set-profile audit 2>/dev/null; cs --session S set-enforcement --skills a --rules security/owasp.md 2>/dev/null
chk "set-profile maps to .profile on the active task (v0.11 skill text keeps the audit branch alive)" 'jq -e ".profile==\"audit\"" "$T2" >/dev/null'
chk "status exposes profile + enforcement_set + artifact paths" 'cs --session S status | jq -e ".task.profile==\"audit\" and .task.enforcement_set==[\"a\",\"security/owasp.md\"] and (.task|has(\"plan_path\") and has(\"review_evidence\") and has(\"scope\"))" >/dev/null'
chk "review SKILL.md command yields {profile, enforcement_set} from the task" '[ -n "$RVCMD" ] && [ "$(rv S)" = "{\"profile\":\"audit\",\"enforcement_set\":[\"a\",\"security/owasp.md\"]}" ]'
chk "review SKILL.md command with no task → nulls, exit 0 (no error)" 'o="$(rv NOTASK)" && [ "$o" = "{\"profile\":null,\"enforcement_set\":null}" ]'
cs --session S set-profile "Bad Word" 2>/dev/null && bad "set-profile accepted a non-word" || ok "set-profile rejects a non-word"
cs --session S set-profile audits 2>/dev/null && bad "set-profile accepted 'audits' (not in the enum)" || ok "set-profile rejects a value outside feature|bugfix|audit|migration|investigation (C3-5)"
chk "a rejected set-profile leaves the profile as it was" 'jq -e ".profile==\"audit\"" "$T2" >/dev/null'
chk "start rejects a --profile outside the enum and claims no task dir" '! cs --session S9 start --route light --slug q --profile audits 2>/dev/null && [ -z "$(ls -d "$P/.claude/claudehut/tasks/"*-q 2>/dev/null)" ]'
CLAUDEHUT_SESSION_ID=S cs --session set-phase plan 2>/dev/null
chk "argv '--session <empty> set-phase plan' (unquoted \${CLAUDE_SESSION_ID}) falls back to \$CLAUDEHUT_SESSION_ID" 'jq -e ".phase==\"plan\"" "$T2" >/dev/null'
printf '["L-1"]\n' > "$P/.claude/claudehut/state/S.injected.json"; printf '{}\n' > "$P/.claude/claudehut/state/S.learn-receipt.json"
chk "no session anywhere → error that names recent sessions" '! cs set-phase plan 2>"$W/ns.err" && grep -q "Recent sessions: S" "$W/ns.err"'
chk "the recent-sessions hint lists pointers only, never <sid>.<kind> sidecars" '! grep -qE "\.(injected|learn-receipt)" "$W/ns.err"'
chk "a dotted session id is rejected, so a pointer can never overwrite a sidecar" \
  '! cs --session S.injected start --route light --slug a 2>/dev/null && jq -e ". == [\"L-1\"]" "$P/.claude/claudehut/state/S.injected.json" >/dev/null'
CLAUDEHUT_SESSION_ID=S cs --session "" set-phase implement 2>/dev/null; r=$?
chk "a quoted empty --session \"\" is consumed and falls back to \$CLAUDEHUT_SESSION_ID" '[ "$r" = 0 ] && jq -e ".phase==\"implement\"" "$T2" >/dev/null'
run_hook advise-write "$P" "$(wpl S "$P/src/main/java/A.java")"
chk "integration: full route, plan not approved → advise-write speaks" 'one_ctx PreToolUse'
rm -f "$P/.claude/claudehut/state/S.nudged"*
LONGP="$P/src/main/ab$(python3 -c "print('ở'*200)" 2>/dev/null || printf 'ở%.0s' $(seq 200)).java"
run_hook advise-write "$P" "$(wpl S "$LONGP")" LC_ALL=C LANG=C
chk "advise-write under LC_ALL=C with a long UTF-8 path: valid UTF-8, fixed text intact (R2-4)" \
  'printf "%s" "$OUT" | python3 -c "import sys,json; t=json.loads(sys.stdin.buffer.read().decode(\"utf-8\"))[\"hookSpecificOutput\"][\"additionalContext\"]; sys.exit(0 if t.endswith(\"once per task.\") and len(t)<=500 else 1)"'
PL="$P/.claude/claudehut/tasks/$id2/plan.md"
printf '%s\n' "$EXPLAN" > "$PL"; printf '%s\n' "$EXSPEC" > "${PL%/*}/spec.md"   # full route: L10 needs the spec
cs --session S set-plan ".claude/claudehut/tasks/$id2/plan.md" 2>/dev/null
chk "set-plan records the plan and sets plan_approved=true" 'jq -e ".plan_approved==true and (.plan_path|test(\"plan.md\"))" "$T2" >/dev/null'
mk_task "$P" S2 0099-z full false; rm -f "$P/.claude/claudehut/state/S.nudged"*
run_hook advise-write "$P" "$(wpl S "$P/src/main/java/A.java")"
chk "integration: after set-plan the same task is silent (nudge marker cleared first, so silence is the predicate)" 'silent'
cs --session S end --status done 2>/dev/null
chk "end: task done, pointer cleared" 'jq -e ".status==\"done\"" "$T2" >/dev/null && jq -e ".active_task==null" "$P/.claude/claudehut/state/S.json" >/dev/null'
chk "resume: a done task cannot be resumed; a superseded one can (new session)" \
  '! cs --session N resume "$id2" 2>/dev/null && cs --session N resume "$id1" 2>/dev/null && jq -e ".status==\"active\" and .session==\"N\"" "$T1" >/dev/null'
printf '{"session":"L","phase":"implement","bypass":true,"complexity":"full"}\n' > "$P/.claude/claudehut/state/L.json"
cs --session L status > "$W/leg.json"
chk "04-AC6: legacy state with bypass=true and no schema → no task (status flags it ignored)" 'jq -e ".active_task==null and .legacy_state_ignored==true" "$W/leg.json" >/dev/null'
cs --session L set-phase implement 2>/dev/null
chk "04-AC6: set-* on a legacy session record nothing and leave the v0.11 file alone" 'jq -e ".bypass==true and (has(\"schema\")|not)" "$P/.claude/claudehut/state/L.json" >/dev/null'

echo "== claudehut-state: task creation is explicit — start only, nothing is guessed from tasks/ (D1–D4, C3-1, C3-2) =="
# Triage before start (the v0.11 Phase 0/0b order): set-complexity / set-profile / set-phase discover with no task.
P="$(new_plane tri)"; cs() { CLAUDE_PROJECT_DIR="$P" "$ST" "$@"; }; TD="$P/.claude/claudehut/tasks"
: > "$W/tri.err"; r=0
for v in "set-complexity small" "set-profile audit" "set-phase discover"; do
  # shellcheck disable=SC2086
  cs --session tri $v 2>>"$W/tri.err" || r=1
done
chk "triage before start: set-complexity / set-profile / set-phase discover are notices, exit 0 (D3, 04-AC7)" '[ "$r" = 0 ] && [ "$(grep -c "no active task" "$W/tri.err")" = 3 ]'
chk "triage before start writes nothing: no state/<sid>.json, no pointer hint, no tasks/ (D3, 04-AC7)" \
  '[ ! -e "$P/.claude/claudehut/state/tri.json" ] && [ ! -e "$TD" ]'
# The skill order after the fix: triage → start --route --profile --slug → set-phase discover → …
SO="$(cs --session tri start --route light --profile audit --slug audit-x 2>/dev/null)"
cs --session tri set-phase discover 2>/dev/null; cs --session tri set-enforcement --skills a,b --rules x.md 2>/dev/null
chk "start carries the triage: route + profile land on the task discover then records on (C3-1)" \
  'cs --session tri status | jq -e ".task|.id==\"0001-audit-x\" and .route==\"light\" and .profile==\"audit\" and .phase==\"discover\"" >/dev/null'
chk "the review SKILL.md command reads the profile start recorded (audit branch reachable, C3-1)" '[ "$(rv tri)" = "{\"profile\":\"audit\",\"enforcement_set\":[\"a\",\"b\",\"x.md\"]}" ]'
cs --session tri set-complexity full 2>/dev/null; cs --session tri set-profile investigation 2>/dev/null
chk "set-complexity / set-profile with a task open update that task only (route full, profile investigation)" \
  'jq -e ".route==\"full\" and .profile==\"investigation\"" "$TD/0001-audit-x/task.json" >/dev/null && [ "$(ls "$TD" | wc -l | tr -d " ")" = 1 ]'
chk "the pointer stays a pointer (no next_route / hint fields)" 'jq -e ". == {schema:2, active_task:\"0001-audit-x\"}" "$P/.claude/claudehut/state/tri.json" >/dev/null'

# Second task in one session (C3-2, D4): task 1 runs to review pass + learn; the next request's triage and
# set-phase discover must never touch it, and task 2 inherits none of its fields.
P="$(new_plane two)"; cs() { CLAUDE_PROJECT_DIR="$P" "$ST" "$@"; }; TD="$P/.claude/claudehut/tasks"
cs --session sB start --route full --profile feature --slug a >/dev/null 2>&1; T="$TD/0001-a"
printf '| Dimension | Existing asset | Decision | Fit | Impact | Effort |\n|a|b|reuse|1|1|1|\n' > "$T/reuse-scan.md"
cs --session sB set-reuse-scan --artifact .claude/claudehut/tasks/0001-a/reuse-scan.md 2>/dev/null
printf '# F\n- x (A.java:1)\n' > "$T/findings.md"; cs --session sB set-findings .claude/claudehut/tasks/0001-a/findings.md 2>/dev/null
printf '| AC-1 | ✓ satisfied | Foo.java:1 |\n./gradlew test — 3 passed\n' > "$T/review.md"
cs --session sB set-review pass --evidence .claude/claudehut/tasks/0001-a/review.md 2>/dev/null; cs --session sB set-phase learn 2>/dev/null
cs --session sB set-phase discover 2>"$W/fin.err"
chk "set-phase discover on a finished task never opens or adopts a task; the notice points at start (C3-2)" \
  '[ "$(ls "$TD" | wc -l | tr -d " ")" = 1 ] && [ "$(cs --session sB status | jq -r .active_task)" = 0001-a ] && grep -q "claudehut-state start" "$W/fin.err"'
cs --session sB set-phase learn 2>/dev/null; h1="$(jq -S 'del(.status, .superseded_by, .ended, .updated)' "$T/task.json" | shasum)"
cs --session sB start --route light --profile bugfix --slug b >/dev/null 2>&1; T2="$TD/0002-b/task.json"
chk "second task in a session: start closes the finished task 1 as done and leaves every other field of it untouched (D4, C3-2, R2-C1)" \
  'jq -e ".status==\"done\" and .superseded_by==\"0002-b\" and .route==\"full\" and .profile==\"feature\" and .review==\"pass\"" "$T/task.json" >/dev/null && [ "$(jq -S "del(.status, .superseded_by, .ended, .updated)" "$T/task.json" | shasum)" = "$h1" ]'
chk "second task in a session: task 2 inherits no review / reuse_scan / findings_path of task 1 (C3-2)" \
  'jq -e ".review==\"pending\" and (has(\"reuse_scan\")|not) and (has(\"reuse_scan_artifact\")|not) and (has(\"findings_path\")|not) and (has(\"review_evidence\")|not) and .route==\"light\" and .profile==\"bugfix\"" "$T2" >/dev/null'
cs --session sB end --status done 2>/dev/null; hd="$(shasum "$T2")"
cs --session sB set-complexity full 2>/dev/null; cs --session sB set-profile migration 2>/dev/null
chk "after end, the next request's triage (set-complexity / set-profile) changes no task and writes no hint (D4)" \
  '[ "$(shasum "$T2")" = "$hd" ] && jq -e ". == {schema:2, active_task:null}" "$P/.claude/claudehut/state/sB.json" >/dev/null'

# Two sessions on one plane (D1): a dir another session (or a v0.11 skill) created is never adopted.
P="$(new_plane duo)"; cs() { CLAUDE_PROJECT_DIR="$P" "$ST" "$@"; }; TD="$P/.claude/claudehut/tasks"
ida="$(cs --session A start --route full --slug a 2>/dev/null | head -1)"
mkdir -p "$TD/0002-b"   # session B's v0.11 Discover step 1 made this dir by hand
idb="$(cs --session B start --route full --slug b 2>/dev/null | head -1)"
cs --session A set-phase discover 2>/dev/null; mkdir -p "$TD/0004-c"; cs --session A set-phase discover 2>/dev/null
chk "two sessions: each start allocates its own task; a hand-made dir is skipped, never adopted (D1)" \
  '[ "$ida" = 0001-a ] && [ "$idb" = 0003-b ] && [ ! -e "$TD/0002-b/task.json" ] && [ ! -e "$TD/0004-c/task.json" ]'
chk "two sessions: set-phase discover re-entry in A stays on A's task and supersedes nothing (D1)" \
  '[ "$(cs --session A status | jq -r .active_task)" = 0001-a ] && [ "$(cs --session B status | jq -r .active_task)" = 0003-b ] && jq -e ".status==\"active\"" "$TD/0001-a/task.json" "$TD/0003-b/task.json" >/dev/null'
cs --session A start --route light --slug a2 >/dev/null 2>&1
chk "two sessions: A's next start supersedes only A's task; B's task is untouched (D1)" \
  'jq -e ".status==\"superseded\"" "$TD/0001-a/task.json" >/dev/null && jq -e ".status==\"active\" and .session==\"B\"" "$TD/0003-b/task.json" >/dev/null'
chk "start never adopts an existing tasks/NNNN-<slug>/ of the same slug: it takes the next number" \
  '[ "$(cs --session Z start --route light --slug c 2>/dev/null | head -1)" = 0006-c ]'

# A stale v0.11 task dir with a FRESH mtime (cp -R / clone / checkout reset it, D2): mtime decides nothing now.
S11="$W/v011src"; mkdir -p "$S11/.claude/claudehut/tasks/0009-legacy"; printf '# scan\n' > "$S11/.claude/claudehut/tasks/0009-legacy/reuse-scan.md"
touch -t 202601010000 "$S11/.claude/claudehut/tasks/0009-legacy"; cp -R "$S11" "$W/v011copy"; P="$W/v011copy"; cs() { CLAUDE_PROJECT_DIR="$P" "$ST" "$@"; }
cs --session z set-phase discover 2>/dev/null
chk "stale v0.11 dir (cp -R, fresh mtime): set-phase discover creates and adopts nothing (D2, ADR-R2)" \
  '[ ! -e "$P/.claude/claudehut/tasks/0009-legacy/task.json" ] && [ ! -e "$P/.claude/claudehut/state/z.json" ]'
chk "stale v0.11 dir: start allocates the next number instead (0010-*), the v0.11 dir stays task.json-free (D2)" \
  '[ "$(cs --session z start --route light --slug fresh 2>/dev/null | head -1)" = 0010-fresh ] && [ ! -e "$P/.claude/claudehut/tasks/0009-legacy/task.json" ]'
cs --session z set-phase discover --task 0009-legacy 2>"$W/tk.err"
chk "set-phase --task <other> (m0 flag) is not honoured: notice pointing at resume, the phase stays on the open task" \
  'grep -q "resume 0009-legacy" "$W/tk.err" && [ "$(cs --session z status | jq -r .active_task)" = 0010-fresh ]'

# Past 9999 (V3-2): numbering reads every digit and compares numerically, so 10000-* is seen and never reused.
P="$(new_plane big)"; cs() { CLAUDE_PROJECT_DIR="$P" "$ST" "$@"; }; mkdir -p "$P/.claude/claudehut/tasks/9999-x" "$P/.claude/claudehut/tasks/0998-y"
big="$(cs --session r1 start --route light --slug a 2>/dev/null | head -1) $(cs --session r2 start --route light --slug b 2>/dev/null | head -1) $(cs --session r3 start --route light --slug c 2>/dev/null | head -1)"
chk "task numbers past 9999: 9999-x → 10000-a, 10001-b, 10002-c (distinct, numeric order; V3-2)" '[ "$big" = "10000-a 10001-b 10002-c" ]'

echo "== claudehut-state: ownership after resume (V2-5) =="
P="$(new_plane own)"; cs() { CLAUDE_PROJECT_DIR="$P" "$ST" "$@"; }; TD="$P/.claude/claudehut/tasks"
cs --session parent start --route full --slug work >/dev/null 2>&1; cs --session fork resume 0001-work 2>/dev/null
cs --session parent start --route light --slug side >/dev/null 2>&1
chk "start in the original session does not supersede a task a fork resumed" 'jq -e ".status==\"active\" and .session==\"fork\"" "$TD/0001-work/task.json" >/dev/null && [ "$(cs --session fork status | jq -r .active_task)" = 0001-work ]'
cs --session parent resume 0001-work 2>/dev/null; cs --session fork end --status done 2>/dev/null
chk "end closes only the owner's task; another session's end just clears its own pointer" 'jq -e ".status==\"active\" and .session==\"parent\"" "$TD/0001-work/task.json" >/dev/null && [ "$(cs --session fork status | jq -r .active_task)" = null ]'

# A stale session never writes into a task another session resumed (V1-1, C1): set-* treat it as no task.
P="$(new_plane own2)"; cs() { CLAUDE_PROJECT_DIR="$P" "$ST" "$@"; }; TO="$P/.claude/claudehut/tasks/0001-t1/task.json"
cs --session A start --route full --profile feature --slug t1 >/dev/null 2>&1; cs --session B resume 0001-t1 2>/dev/null
chk "resume clears the previous owner's pointer, so A's hooks stop reading B's task (V1-1)" \
  'jq -e ". == {schema:2, active_task:null}" "$P/.claude/claudehut/state/A.json" >/dev/null && jq -e ".session==\"B\"" "$TO" >/dev/null'
printf '{"schema":2,"active_task":"0001-t1"}\n' > "$P/.claude/claudehut/state/A.json"   # a stale pointer (older build, a race)
hb="$(shasum "$TO")"; : > "$W/own2.err"; r=0
for v in "set-phase implement" "set-route light" "set-review pending" "set-outstanding []" "set-profile bugfix" "set-complexity small"; do
  # shellcheck disable=SC2086
  cs --session A $v 2>>"$W/own2.err" || r=1
done
chk "after B resumes, A's set-phase / set-route / set-review / … leave B's task byte-identical, exit 0 (V1-1, C1)" \
  '[ "$r" = 0 ] && [ "$(shasum "$TO")" = "$hb" ] && [ "$(grep -c "owned by session B" "$W/own2.err")" = 6 ] && grep -q "resume 0001-t1" "$W/own2.err"'
chk "status of the stale session: active_task null + resumed_elsewhere names the task and its owner (V1-1)" \
  'cs --session A status | jq -e ".active_task==null and .resumed_elsewhere=={task:\"0001-t1\",session:\"B\"}" >/dev/null'
run_hook advise-write "$P" "$(wpl A "$P/src/main/java/A.java")"
chk "hooks of the stale session do not read B's task as theirs either (advise-write silent for A)" 'silent && errlog_empty "$P"'
run_hook advise-write "$P" "$(wpl B "$P/src/main/java/A.java")"
chk "control: the owner B still gets the advisory on its own full-route task" 'one_ctx PreToolUse'
printf '{"schema":2,"active_task":"0001-t1"}\n' > "$P/.claude/claudehut/state/A.json"
cs --session A end --status done 2>/dev/null
chk "A's end on B's task clears only A's pointer; B's task stays active and byte-identical (V1-1)" \
  '[ "$(shasum "$TO")" = "$hb" ] && jq -e ".active_task==null" "$P/.claude/claudehut/state/A.json" >/dev/null && [ "$(cs --session B status | jq -r .active_task)" = 0001-t1 ]'
chk "A starting a new request after that opens its own task and leaves B's alone" \
  '[ "$(cs --session A start --route light --slug t2 2>/dev/null | head -1)" = 0002-t2 ] && [ "$(shasum "$TO")" = "$hb" ]'

echo "== claudehut-state: a task that skips Learn is closed where it finishes (V1-2, C2) =="
P="$(new_plane triv)"; cs() { CLAUDE_PROJECT_DIR="$P" "$ST" "$@"; }; TD="$P/.claude/claudehut/tasks"
D1="$(cs --session tv start --route light --profile bugfix --slug first 2>/dev/null | sed -n 2p)"
cs --session tv set-phase discover 2>/dev/null
printf '| Dimension | Existing asset | Decision | Fit | Impact | Effort |\n|a|b|reuse|1|1|1|\n' > "$P/${D1}reuse-scan.md"
cs --session tv set-reuse-scan --artifact "${D1}reuse-scan.md" 2>/dev/null; cs --session tv set-phase review 2>/dev/null
printf '| AC-1 | ✓ satisfied | Foo.java:1 |\n./gradlew test — 3 passed\n' > "$P/${D1}review.md"
cs --session tv set-review pass --evidence "${D1}review.md" 2>/dev/null
# The NEXT request in the old v0.11 order (no end, no start): every front-of-pipeline verb, each with a valid
# artifact of its own, so a write would succeed if the guard let it through (R2-1, R2-C1).
X=".claude/claudehut/tasks/x"; mkdir -p "$P/$X"
printf '| Dimension | Existing asset | Decision | Fit | Impact | Effort |\n|c|d|new|1|1|1|\n' > "$P/$X/reuse-scan.md"
printf '# B\n| # | option | score |\n|0|adopt|1|\n|1|new|2|\n## Premortem\nx\n## Recommendation\n0\n' > "$P/$X/brainstorm.md"
printf '## 1\nAC-001 Given\n## 9 Decision\nx\n' > "$P/$X/spec.md"; printf '| T-001 | a | t | v | - |\n' > "$P/$X/plan.md"
printf '| Check | Status | Evidence |\n| AC-001 covered | ✓ | T-001 |\n' > "$P/$X/plan-review.md"
h1="$(shasum "$TD/0001-first/task.json")"; : > "$W/triv.err"; r=0
for v in "set-complexity small" "set-profile feature" "set-phase discover" "set-reuse-scan --artifact $X/reuse-scan.md" \
         "set-phase brainstorm" "set-brainstorm $X/brainstorm.md" "set-enforcement --skills a --rules b.md" \
         "set-phase spec" "set-spec $X/spec.md" "set-phase plan" "set-plan-review APPROVE --evidence $X/plan-review.md" \
         "set-plan $X/plan.md" "set-route full" "set-phase implement"; do
  # shellcheck disable=SC2086
  cs --session tv $v 2>>"$W/triv.err" || r=1
done
chk "finished task (review pass), next request in the old order (14 verbs, no end/start): task 1 stays byte-identical, exit 0 (R2-1, R2-C1)" \
  '[ "$r" = 0 ] && [ "$(shasum "$TD/0001-first/task.json")" = "$h1" ]'
chk "each of those 14 verbs printed the finished notice pointing at start" \
  '[ "$(grep -c "already finished" "$W/triv.err")" = 14 ] && grep -q "claudehut-state start --route" "$W/triv.err"'
# R3-C2: the next request's REVIEW verbs (it skipped start; implement makes no state call) must not overwrite the
# finished task's review either: set-phase review, set-outstanding, set-review pending|capped, and a set-review pass
# whose evidence is another dir's review.md all record nothing. Its own closing records still land.
mkdir -p "$P/.claude/claudehut/tasks/tmp3"; printf '| AC-9 | ✓ satisfied | Bar.java:2 |\n./gradlew test — 4 passed\n' > "$P/.claude/claudehut/tasks/tmp3/review.md"
: > "$W/triv2.err"; r=0
for v in "set-phase review" "set-outstanding '[\"x\"]'" "set-review pending" "set-review capped" "set-review pass --evidence .claude/claudehut/tasks/tmp3/review.md"; do
  eval "cs --session tv $v" 2>>"$W/triv2.err" || r=1
done
chk "finished task: a new request's review verbs (set-phase review, set-outstanding, set-review pending|capped|pass elsewhere) record nothing, exit 0 (R3-C2)" \
  '[ "$r" = 0 ] && [ "$(shasum "$TD/0001-first/task.json")" = "$h1" ] && [ "$(grep -c "already finished" "$W/triv2.err")" = 5 ]'
cs --session tv set-review pass --evidence "${D1}review.md" 2>/dev/null; rp=$?; cs --session tv set-phase learn 2>/dev/null
chk "finished task: its own closing records still land (set-review pass with its own review.md, set-phase learn; R3-C2)" \
  '[ "$rp" = 0 ] && jq -e ".phase==\"learn\" and .review==\"pass\" and (.review_evidence|test(\"0001-first/review.md\")) and (has(\"outstanding\")|not)" "$TD/0001-first/task.json" >/dev/null'
cs --session tv end --status done 2>/dev/null   # the review skill's Exit for a task that skips Learn
h1="$(jq -S 'del(.updated)' "$TD/0001-first/task.json" | shasum)"
D2="$(cs --session tv start --route light --profile bugfix --slug second 2>/dev/null | sed -n 2p)"
cs --session tv set-phase discover 2>/dev/null
printf '| Dimension | Existing asset | Decision | Fit | Impact | Effort |\n|c|d|new|1|1|1|\n' > "$P/${D2}reuse-scan.md"
cs --session tv set-reuse-scan --artifact "${D2}reuse-scan.md" 2>/dev/null
chk "trivial task then a second request: task 1 is done and untouched, task 2 has its own dir and no review pass (V1-2)" \
  'jq -e ".status==\"done\" and .review==\"pass\"" "$TD/0001-first/task.json" >/dev/null && [ "$(jq -S "del(.updated)" "$TD/0001-first/task.json" | shasum)" = "$h1" ] && [ "$D2" = ".claude/claudehut/tasks/0002-second/" ] && jq -e ".review==\"pending\" and (has(\"review_evidence\")|not) and (.reuse_scan_artifact|test(\"0002-second\"))" "$TD/0002-second/task.json" >/dev/null'
# An audit that recorded findings: a new request's discovery (set-phase discover, set-reuse-scan) records nothing,
# and so does a shape change — profile and route are fixed at start (04 §3), so a new shape is `start --profile`.
# The review OF the findings (the audit profile's Review phase) still records.
P="$(new_plane fnd)"; cs() { CLAUDE_PROJECT_DIR="$P" "$ST" "$@"; }; TD="$P/.claude/claudehut/tasks"
cs --session fa start --route light --profile investigation --slug q >/dev/null 2>&1
printf '# Findings\n- x (A.java:1)\n' > "$TD/0001-q/findings.md"; cs --session fa set-findings .claude/claudehut/tasks/0001-q/findings.md 2>/dev/null
printf '| Dimension | Existing asset | Decision | Fit | Impact | Effort |\n|c|d|new|1|1|1|\n' > "$TD/0001-q/rs2.md"
hf="$(shasum "$TD/0001-q/task.json")"
cs --session fa set-phase discover 2>/dev/null; cs --session fa set-reuse-scan --artifact .claude/claudehut/tasks/0001-q/rs2.md 2>/dev/null
chk "findings recorded: set-phase discover + set-reuse-scan of a new request leave the task byte-identical (R2-1)" '[ "$(shasum "$TD/0001-q/task.json")" = "$hf" ]'
cs --session fa set-profile bugfix 2>"$W/fnd.err"; cs --session fa set-route full 2>>"$W/fnd.err"; cs --session fa set-complexity full 2>>"$W/fnd.err"
chk "findings recorded: a shape change (set-profile / set-route / set-complexity) records nothing and points at start --profile (V3-6)" \
  '[ "$(shasum "$TD/0001-q/task.json")" = "$hf" ] && [ "$(grep -c "already finished" "$W/fnd.err")" = 3 ] && grep -q "change of profile/route, gets its own task: claudehut-state start" "$W/fnd.err"'
printf '| F-1 | ✓ satisfied | A.java:1 |\n./gradlew test — 1 passed\n' > "$TD/0001-q/review.md"; printf '| F-1 | ✓ satisfied | A.java:1 |\n./gradlew test — 1 passed\n' > "$TD/0001-q/../rv-elsewhere.md"
cs --session fa set-review pass --evidence .claude/claudehut/tasks/rv-elsewhere.md 2>/dev/null
chk "findings recorded: set-review pass with another dir's evidence records nothing (R3-C2)" '[ "$(shasum "$TD/0001-q/task.json")" = "$hf" ]'
cs --session fa set-phase review 2>/dev/null; cs --session fa set-outstanding '[]' 2>/dev/null; cs --session fa set-review pass --evidence .claude/claudehut/tasks/0001-q/review.md 2>/dev/null
chk "findings recorded: the review of the findings still records (set-phase review, set-outstanding, set-review pass with its own review.md)" \
  'jq -e ".phase==\"review\" and .outstanding==[] and .review==\"pass\" and .profile==\"investigation\"" "$TD/0001-q/task.json" >/dev/null'
chk "the shape-change rule is stated the same way in the workflow skill and in discover (V3-6)" \
  'grep -q "changes shape after it finished" "$ROOT/skills/claudehut-workflow/SKILL.md" && grep -q "start --profile <new>" "$ROOT/skills/claudehut-workflow/SKILL.md" && ! grep -q "it updates the open task" "$ROOT/skills/claudehut-workflow/SKILL.md" && grep -q "findings_path. set: that is a previous request" "$ROOT/skills/discover/SKILL.md"'
cs --session fa start --route light --slug next >/dev/null 2>&1
chk "start after a findings task closes it as done, not superseded (R2-C1)" 'jq -e ".status==\"done\" and .superseded_by==\"0002-next\"" "$TD/0001-q/task.json" >/dev/null'
cs --session fa start --route light --slug third >/dev/null 2>&1
chk "control: start over an UNFINISHED task still marks it superseded" 'jq -e ".status==\"superseded\"" "$TD/0002-next/task.json" >/dev/null'
chk "the review skill's Exit closes a task that skips Learn; the digest names end; discover's step 1 names resume (V1-2, C2, C6)" \
  'sed -n "/^## Exit/,/^## /p" "$ROOT/skills/review/SKILL.md" | grep -q "end --status done" && grep -q "end --status done" "$ROOT/skills/claudehut-workflow/references/digest.md" && grep -q "resume <id>" "$ROOT/skills/discover/SKILL.md" && grep -q "resume <id>" "$ROOT/skills/claudehut-workflow/SKILL.md"'
chk "no skill tells the model to run set-bypass or a set-findings path outside .claude/claudehut/ (V1-5, C3, C8)" \
  '! grep -rnE "set-bypass true|set-findings tasks/" "$ROOT/skills" >/dev/null'
chk "no skill or agent BODY describes a removed deny gate as live: no write gate / skill rail / hook-gated / denied write (R2-C4)" \
  '! grep -rniE "write gate|skill[ -]rail|hook-gated|write (is|was) denied|every production write .*denied" "$ROOT/skills" "$ROOT/agents" --include=*.md | grep -v summer-kb | grep -q .'
# R3-C3: the same for eval prompts fed to a live model and eval comments. Excluded on purpose: this file (it
# asserts the gate's deletion and replays the v0.11 gate as a fixture). tasks/shortcut-attempt, whose oracle
# observed the gate, was deleted in M2; its "skip workflow" scenario is router-eval case rc-04.
chk "no eval prompt or comment describes the removed write gate as live (probes, conformance, .diag; R3-C3)" \
  '! grep -niE "write gate|gate-write" "$ROOT"/evals/*.sh "$ROOT/evals/.diag.sh" "$ROOT"/evals/lib/*.sh 2>/dev/null | grep -v "^$ROOT/evals/hook-tests.sh:" | grep -q .'
chk "discover branches on the tier recorded as route light/full, not on an unrecorded complexity tier (R2-5)" \
  '! grep -q "recorded complexity tier" "$ROOT/skills/discover/SKILL.md" && grep -q "recorded as route" "$ROOT/skills/discover/SKILL.md"'

echo "== hook-common / record-failure: diagnostics and concurrency (HC-2, HC-3) =="
P="$(new_plane hc)"
run_hook inject-phase "$P" '"str"'
chk "a failing hook logs the failing command's real exit status, not rc=0 (HC-2)" \
  'silent && grep -qE "inject-phase.sh failed rc=[1-9][0-9]* " "$P/.claude/claudehut/state/hook-errors.log"'
FPL='{"session_id":"f1","tool_name":"Bash","tool_input":{"command":"same"},"error":"Exit code 1\nx"}'
for i in $(seq 1 15); do printf '%s' "$FPL" | CLAUDE_PROJECT_DIR="$P" bash "$ROOT/scripts/record-failure.sh" >/dev/null 2>&1 & done; wait
chk "record-failure: 15 concurrent identical failures → exactly one record with hits 15 (HC-3)" \
  '[ "$(wc -l < "$P/.claude/claudehut/state/f1.failures.jsonl" | tr -d " ")" = 1 ] && jq -e ".hits==15" "$P/.claude/claudehut/state/f1.failures.jsonl" >/dev/null && [ ! -e "$P/.claude/claudehut/state/f1.failures.jsonl.lock" ]'

# HC2-1: a STALE lock (killed async holder) must be broken on GNU/Linux too. There `stat -f` means --file-system:
# `stat -f %m` prints a multi-line report and exits 1, and the old BSD-first probe fed that report to `[ -gt ]`,
# so the lock was never broken (3.4 s spin + 1,200 log lines per failure, unlocked). A GNU-like `stat` on PATH
# reproduces that on macOS too; on Linux it delegates to the real GNU stat, so the case is identical on both.
RSTAT="$(command -v stat)"; GS="$W/gnustat"; mkdir -p "$GS"
if "$RSTAT" -c %Y / >/dev/null 2>&1; then mt='exec '"$RSTAT"' -c %Y "$3"'; else mt='exec '"$RSTAT"' -f %m "$3"'; fi
printf '#!/bin/sh\ncase "$1" in\n  -f) printf "  File: \\"%%s\\"\\n    ID: 1 Namelen: 255 Type: overlayfs\\nBlock size: 4096\\n" "$3"; exit 1 ;;\n  -c) [ "$2" = %%Y ] && %s ;;\nesac\nexec %s "$@"\n' "$mt" "$RSTAT" > "$GS/stat"; chmod +x "$GS/stat"
chk "GNU-like stat shim: -f prints a report and fails, -c %Y prints the epoch" '! PATH="$GS:$PATH" stat -f %m / >/dev/null 2>&1 && PATH="$GS:$PATH" stat -c %Y / | grep -qE "^[0-9]+$"'
# No wall clock in these verdicts (V3-3): a PATH shim counts the lock loops' waits instead. Every lock loop here
# yields with an external `sleep`, so "broken at once" is "zero sleeps" — a property, not a load-dependent time.
CNT="$W/cnt"; mkdir -p "$CNT"; export CNT_LOG="$W/cnt.log"
printf '#!/bin/sh\necho sleep >> "$CNT_LOG"\nexec %s "$@"\n' "$(command -v sleep)" > "$CNT/sleep"; chmod +x "$CNT/sleep"
nsleep() { grep -c '^sleep$' "$CNT_LOG" 2>/dev/null || true; }
P="$(new_plane stale)"; SF="$P/.claude/claudehut/state"; mkdir -p "$SF"; FL="$SF/s1.failures.jsonl"
mkdir "$FL.lock"; touch -t 202001010000 "$FL.lock"; : > "$CNT_LOG"
printf '%s' '{"session_id":"s1","tool_name":"Bash","tool_input":{"command":"make"},"error":"Exit code 2"}' | PATH="$CNT:$GS:$PATH" CLAUDE_PROJECT_DIR="$P" bash "$ROOT/scripts/record-failure.sh" >/dev/null 2>&1
ns="$(nsleep)"
chk "record-failure: a stale lock (mtime 2020) under GNU stat is broken at once — lock gone, record written, 0 waits (got $ns), nothing logged (HC2-1)" \
  '[ ! -e "$FL.lock" ] && jq -e ".command==\"make\" and .exit==\"2\"" "$FL" >/dev/null && [ "$ns" = 0 ] && errlog_empty "$P"'
# V3-C1: the steal must re-check under a token. The interleaving is BUILT, not sampled: a `stat` shim on the
# waiter's PATH returns the stale mtime it read, and in that same instant (inside the waiter's decide→remove window)
# another waiter breaks the stale lock and writer C takes a FRESH one, which it holds for 0.3 s. `rm`/`rmdir` shims
# log any removal of the lock path while C holds it. The old one-observation steal deleted C's lock there.
RC_="$W/rcsteal"; mkdir -p "$RC_"; export RS_LOG="$W/rs.log" RS_HELD="$W/rs-held" RS_DONE="$W/rs-swapped"
cat > "$RC_/stat" <<RSEOF
#!/bin/sh
for a; do last="\$a"; done
case "\$last" in *.failures.jsonl.lock) ;; *) exec $RSTAT "\$@" ;; esac
[ -e "\$RS_DONE" ] && exec $RSTAT "\$@"
out="\$($RSTAT "\$@")" || exit 1
: > "\$RS_DONE"; /bin/rmdir "\$last"; /bin/mkdir "\$last"; : > "\$RS_HELD"
( /bin/sleep 0.3; /bin/rm -f "\$RS_HELD"; /bin/rmdir "\$last" 2>/dev/null ) >/dev/null 2>&1 &
printf '%s\n' "\$out"
RSEOF
for b in rm rmdir; do printf '#!/bin/sh\nfor a; do case "$a" in *.failures.jsonl.lock) [ -e "$RS_HELD" ] && echo "%s while C held" >> "$RS_LOG" ;; esac; done\nexec %s "$@"\n' "$b" "$(command -v $b)" > "$RC_/$b"; done
chmod +x "$RC_"/*
P="$(new_plane rsteal)"; SF="$P/.claude/claudehut/state"; mkdir -p "$SF"; FL="$SF/s1.failures.jsonl"
mkdir "$FL.lock"; touch -t 202001010000 "$FL.lock"; : > "$RS_LOG"; rm -f "$RS_DONE" "$RS_HELD"
printf '%s' '{"session_id":"s1","tool_name":"Bash","tool_input":{"command":"make"},"error":"Exit code 2"}' | PATH="$RC_:$PATH" CLAUDE_PROJECT_DIR="$P" bash "$ROOT/scripts/record-failure.sh" >/dev/null 2>&1
for _i in $(seq 1 100); do [ -e "$RS_HELD" ] || break; sleep 0.05; done
chk "record-failure: a steal decided on a stale observation never removes the fresh lock another writer took meanwhile (V3-C1)" \
  '[ -e "$RS_DONE" ] && [ ! -s "$RS_LOG" ] && jq -e ".command==\"make\"" "$FL" >/dev/null && [ ! -e "$FL.lock" ] && [ ! -e "$FL.lock.steal" ]'
cs() { CLAUDE_PROJECT_DIR="$P" "$ST" "$@"; }
cs --session s1 start --route light --slug st >/dev/null 2>&1
mkdir "$SF/.state.lock"; touch -t 202001010000 "$SF/.state.lock"
: > "$CNT_LOG"; PATH="$CNT:$GS:$PATH" cs --session s1 set-route full >/dev/null 2>&1; ns="$(nsleep)"
# Without flock (macOS, the mkdir-lock path) the stale dir must be stolen at once; with flock (Linux) the mkdir
# lock is not used at all, so the dir is left alone and the write still lands immediately.
if command -v flock >/dev/null 2>&1; then lkok='[ -d "$SF/.state.lock" ]'; else lkok='[ ! -e "$SF/.state.lock" ]'; fi
chk "claudehut-state: a stale .state.lock (mtime 2020) under GNU stat does not stall the write (0 waits, got $ns; write lands, HC2-1)" \
  '[ "$ns" = 0 ] && jq -e ".route==\"full\"" "$P/.claude/claudehut/tasks/0001-st/task.json" >/dev/null && eval "$lkok"'
rm -rf "$SF/.state.lock"

# HC2-2 / K3: a plane whose state/ cannot be written (mounted or checked-out hub). No hook may print to its real
# stderr — Claude Code shows hook stderr in the transcript. run_hook discards stderr, so each hook is called
# directly here. Three shapes: state/ is a FILE (holds even as root), state/ mode 555, hook-errors.log mode 444
# (the last two only when not root, which ignores modes — CI and local runs are not root).
ro_leak=""; ro_modes="file"; [ "$(id -u)" = 0 ] || ro_modes="file dir log"
for mode in $ro_modes; do
  P="$W/ro-$mode"; mkdir -p "$P/.claude/claudehut" "$P/src/main/java/a"; printf 'class Foo {}\n' > "$P/src/main/java/a/Foo.java"
  case "$mode" in
    file) : > "$P/.claude/claudehut/state" ;;
    dir)  mkdir -p "$P/.claude/claudehut/state"; chmod 555 "$P/.claude/claudehut/state" ;;
    log)  mkdir -p "$P/.claude/claudehut/state"; : > "$P/.claude/claudehut/state/hook-errors.log"; chmod 444 "$P/.claude/claudehut/state/hook-errors.log" ;;
  esac
  for h in $HOOKS; do
    pl="$(jq -nc --arg f "$P/src/main/java/a/Foo.java" '{session_id:"s1",source:"startup",prompt:"fix the settlement bug",tool_name:"Bash",
      tool_input:{command:"x",subagent_type:"claudehut:claudehut-planner",name:"n",file_path:$f},file_path:"/x",load_reason:"r",
      agent_id:"a1",agent_type:"n",error:"Exit code 1\nboom"}')"
    e="$(printf '%s' "$pl" | CLAUDE_PROJECT_DIR="$P" bash "$ROOT/scripts/$h.sh" 2>&1 >/dev/null)"; rc=$?
    { [ -z "$e" ] && [ "$rc" = 0 ]; } || ro_leak="$ro_leak $mode/$h(rc=$rc: ${e:0:80})"
  done
done
chmod -R u+w "$W"/ro-* 2>/dev/null
chk "read-only plane ($ro_modes): all $(echo $HOOKS | wc -w | tr -d ' ') hooks exit 0 with an EMPTY stderr (HC2-2, K3)${ro_leak:+ — leaked:$ro_leak}" '[ -z "$ro_leak" ]'

echo "== claudehut-state: reuse suspects are per task (V2-1) =="
P="$(new_plane sus)"; mkdir -p "$P/src/main/java"; cs() { CLAUDE_PROJECT_DIR="$P" "$ST" "$@"; }
cs --session su start --route light --slug a >/dev/null 2>&1
printf 'class A { static boolean isBlank(String s){return s==null;} }\n' > "$P/src/main/java/A.java"
run_hook lint-reuse "$P" "$(wpl su "$P/src/main/java/A.java")"
chk "lint-reuse stages the suspect under the task id" '[ -s "$P/.claude/claudehut/state/0001-a.suspects.jsonl" ] && [ ! -e "$P/.claude/claudehut/state/su.suspects.jsonl" ]'
cs --session su end --status done 2>/dev/null; cs --session su start --route light --slug b >/dev/null 2>&1
printf '| item | ✓ satisfied | B.java:1 |\n\n./gradlew test — 12 passed\n' > "$P/.claude/claudehut/tasks/0002-b/review.md"
chk "a suspect of task A does not block set-review pass of task B in the same session" 'cs --session su set-review pass --evidence .claude/claudehut/tasks/0002-b/review.md 2>/dev/null'

echo "== claudehut-state: pre_dirty real paths, keys relative to the project (V2-3, V2-4) =="
P="$(new_plane pd)"; cs() { CLAUDE_PROJECT_DIR="$P" "$ST" "$@"; }
for d in a/svc b/svc; do mkdir -p "$P/$d"; ( cd "$P/$d" && git init -q && echo 1 > f && git add f && git -c user.email=x -c user.name=x commit -qm i && git mv f g && printf 'x\n' > 'tên.md' && printf 'y\n' > 'sp ace.txt' ); done
cs --session m start --route full --slug mr --repo a/svc --repo b/svc >/dev/null 2>&1
TP="$P/.claude/claudehut/tasks/0001-mr/task.json"
chk "two repos with the same basename keep separate base/pre_dirty keys" 'jq -e "(.base|keys)==[\"a/svc\",\"b/svc\"] and (.pre_dirty|keys)==[\"a/svc\",\"b/svc\"]" "$TP" >/dev/null'
chk "pre_dirty holds real paths (space, UTF-8) and the rename target only" 'jq -e ".pre_dirty[\"a/svc\"]==[\"g\",\"sp ace.txt\",\"tên.md\"]" "$TP" >/dev/null'

echo "== claudehut-state: plane-wide lock (kept from 0128b37) =="
P="$(new_plane lock)"; cs() { CLAUDE_PROJECT_DIR="$P" "$ST" "$@"; }
cs --session c start --route full --slug lk >/dev/null 2>&1; TL="$P/.claude/claudehut/tasks/0001-lk/task.json"
lost=0
for _i in 1 2 3 4 5; do
  cs --session c set-route full >/dev/null 2>&1; cs --session c set-outstanding '[]' >/dev/null 2>&1
  cs --session c set-phase discover >/dev/null 2>&1; cs --session c set-enforcement --skills "" --rules "" >/dev/null 2>&1
  cs --session c set-route light >/dev/null 2>&1 &
  cs --session c set-outstanding '["x"]' >/dev/null 2>&1 &
  cs --session c set-phase implement >/dev/null 2>&1 &
  cs --session c set-enforcement --skills a --rules b.md >/dev/null 2>&1 &
  wait
  jq -e '.route=="light" and (.outstanding|length)==1 and .phase=="implement" and (.enforcement_set|length)==2' "$TL" >/dev/null 2>&1 || lost=$((lost+1))
done
chk "lock: 4 concurrent writers on one task, 5 trials, zero lost updates" '[ "$lost" = 0 ]'
: > "$P/.claude/claudehut/state/.state.lock"
lost=0
for _i in 1 2 3; do
  cs --session c set-route full >/dev/null 2>&1; cs --session c set-outstanding '[]' >/dev/null 2>&1
  cs --session c set-route light >/dev/null 2>&1 & cs --session c set-outstanding '["x"]' >/dev/null 2>&1 & wait
  jq -e '.route=="light" and (.outstanding|length)==1' "$TL" >/dev/null 2>&1 || lost=$((lost+1))
  : > "$P/.claude/claudehut/state/.state.lock"
done
chk "lock: a plain file at the lock path is cleared, not read as an unwritable filesystem" '[ "$lost" = 0 ]'
# The 4-writer trials above are TIMING samples. These two pin the 0128b37 holes deterministically, by building
# the interleaving: a stub mkdir (on PATH, acting only on the lock path) releases a held lock INSIDE the window
# of the writer's first failed mkdir. Before 0128b37 the writer read "mkdir failed and no dir" as an unwritable
# filesystem and proceeded unlocked. Meaningful only on the mkdir-lock path (no flock), as in gate-tests at m0.
rm -f "$P/.claude/claudehut/state/.state.lock"
STUB="$W/lkstub"; mkdir -p "$STUB"; export CH_RELEASED="$W/lk-released" CH_RMLOG="$W/lk-rm.log"
cat > "$STUB/mkdir" <<'STUBEOF'
#!/bin/sh
case "$1" in -p) exec /bin/mkdir "$@" ;; esac
case "$1" in */.state.lock) ;; *) exec /bin/mkdir "$@" ;; esac
if /bin/mkdir "$@" 2>/dev/null; then exit 0; fi
# The release is claimed ATOMICALLY (mkdir, not test-then-touch): with a check-then-act marker both writers
# could pass the test, and the second rm then deleted the lock the first had already re-taken (R3-C1).
if /bin/mkdir "$CH_RELEASED" 2>/dev/null; then echo rm >> "$CH_RMLOG"; /bin/rm -rf "$1"; fi
exit 1
STUBEOF
chmod +x "$STUB/mkdir"
lost=0; rms=""
for _i in 1 2 3 4 5; do
  cs --session c set-route full >/dev/null 2>&1; cs --session c set-outstanding '[]' >/dev/null 2>&1
  rm -rf "$CH_RELEASED"; : > "$CH_RMLOG"; mkdir "$P/.claude/claudehut/state/.state.lock"   # a holder
  PATH="$STUB:$PATH" cs --session c set-route light >/dev/null 2>&1 &
  PATH="$STUB:$PATH" cs --session c set-outstanding '["x"]' >/dev/null 2>&1 &
  wait
  jq -e '.route=="light" and (.outstanding|length)==1' "$TL" >/dev/null 2>&1 || lost=$((lost+1))
  rms="$rms$(wc -l < "$CH_RMLOG" | tr -d ' ')"
done
# With flock on PATH (Linux) claudehut-state never takes the mkdir lock, so the stub never runs: 00000 there.
if command -v flock >/dev/null 2>&1; then rmw=00000; else rmw=11111; fi
chk "lock: the stub released the holder exactly once per trial on the mkdir-lock path — the interleaving the next check claims (R3-C1; got $rms, want $rmw)" '[ "$rms" = "$rmw" ]'
chk "lock: a holder releasing INSIDE the failed-mkdir window does not drop a writer (5/5, ported from m0)" '[ "$lost" = 0 ]'
rm -rf "$P/.claude/claudehut/state/.state.lock"
# CONTROL: the retry must not turn a genuine hard failure into a stall (hooks run under 5-15 s timeouts, the
# wall-clock cap is 10 s): a lock mkdir that can never succeed fails OPEN promptly and the write still lands.
HS="$W/lkhard"; mkdir -p "$HS"; printf '#!/bin/sh\ncase "$1" in -p) exec /bin/mkdir "$@" ;; esac\ncase "$1" in */.state.lock) exit 1 ;; esac\nexec /bin/mkdir "$@"\n' > "$HS/mkdir"; chmod +x "$HS/mkdir"
cs --session c set-route full >/dev/null 2>&1
: > "$CNT_LOG"; PATH="$CNT:$HS:$PATH" cs --session c set-route light >/dev/null 2>&1; ns="$(nsleep)"
chk "lock: control — a lock mkdir that can never succeed still fails OPEN promptly (0 waits, got $ns; write lands; ported from m0)" \
  '[ "$ns" = 0 ] && jq -e ".route==\"light\"" "$TL" >/dev/null'
chk "lock: released cleanly (no mkdir lock left behind; the flock file, where flock exists, stays by design)" '[ -z "$(find "$P/.claude/claudehut/state" -name ".state.lock*" ! -name ".state.lock.flock" 2>/dev/null)" ]'
# R2-3: the FLOCK path (Linux, and CI). Release used to unlink state/.state.lock.flock; a waiter that had already
# opened it then held a lock on a dead inode while a newcomer locked a fresh file (two holders). A python fcntl
# `flock` on PATH forces this path on macOS too. The pin is deterministic: the lock file keeps ONE inode across
# writers (it is never unlinked); the concurrent loop after it is a timing sample of the same property.
FS="$W/flockshim"; mkdir -p "$FS"
cat > "$FS/flock" <<'FLEOF'
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
chmod +x "$FS/flock"
P="$(new_plane flk)"; cs() { CLAUDE_PROJECT_DIR="$P" PATH="$FS:$PATH" "$ST" "$@"; }; FF="$P/.claude/claudehut/state/.state.lock.flock"
cs --session f start --route full --slug fl >/dev/null 2>&1; TL="$P/.claude/claudehut/tasks/0001-fl/task.json"
i1="$(ls -i "$FF" 2>/dev/null | awk '{print $1}')"; cs --session f set-route light >/dev/null 2>&1; cs --session f set-route full >/dev/null 2>&1
i2="$(ls -i "$FF" 2>/dev/null | awk '{print $1}')"
chk "flock path: the lock file is never unlinked — one inode across writers (R2-3)" '[ -n "$i1" ] && [ "$i1" = "$i2" ] && [ ! -e "$P/.claude/claudehut/state/.state.lock" ]'
lost=0
for _i in 1 2 3 4 5; do
  cs --session f set-route full >/dev/null 2>&1; cs --session f set-outstanding '[]' >/dev/null 2>&1
  cs --session f set-phase discover >/dev/null 2>&1; cs --session f set-enforcement --skills "" --rules "" >/dev/null 2>&1
  cs --session f set-route light >/dev/null 2>&1 & cs --session f set-outstanding '["x"]' >/dev/null 2>&1 &
  cs --session f set-phase implement >/dev/null 2>&1 & cs --session f set-enforcement --skills a --rules b.md >/dev/null 2>&1 &
  wait
  jq -e '.route=="light" and (.outstanding|length)==1 and .phase=="implement" and (.enforcement_set|length)==2' "$TL" >/dev/null 2>&1 || lost=$((lost+1))
done
chk "flock path: 4 concurrent writers on one task, 5 trials, zero lost updates (R2-3)" '[ "$lost" = 0 ]'
P="$W/lock"; cs() { CLAUDE_PROJECT_DIR="$P" "$ST" "$@"; }
two="$( (cs --session a start --route light --slug p1 2>/dev/null & cs --session b start --route light --slug p2 2>/dev/null & wait) | grep -v / | sort | cut -c1-4 | tr '\n' ' ')"
chk "lock: two sessions starting at once get distinct task numbers" '[ "$two" = "0002 0003 " ]'

echo "== claudehut-state: set-review pass earned evidence (kept) =="
P="$(new_plane rv)"; cs() { CLAUDE_PROJECT_DIR="$P" "$ST" "$@"; }
cs --session s start --route full --slug x >/dev/null 2>&1; TD="$P/.claude/claudehut/tasks/0001-x"; ev="$TD/review.md"
chk "reject: pass without --evidence" '! cs --session s set-review pass 2>/dev/null'
chk "reject: evidence file must exist" '! cs --session s set-review pass --evidence "$ev" 2>/dev/null'
printf '# Review\nAll requirements are satisfied. Tests are passing.\n' > "$ev"
chk "reject: prose with keywords but no table row" '! cs --session s set-review pass --evidence "$ev" 2>/dev/null'
printf '# Review\n| x | ✓ satisfied | A.java:1 |\n' > "$ev"
chk "reject: no test evidence" '! cs --session s set-review pass --evidence "$ev" 2>/dev/null'
printf '# Review\n| x | ✓ satisfied | looks fine |\n./gradlew test — 3 passed\n' > "$ev"
chk "reject: a ✓ row with no evidence locus" '! cs --session s set-review pass --evidence "$ev" 2>/dev/null'
printf '| x | ✓ | A.java:1 |\n./gradlew test 5 passed\n' > "$W/bad-review.md"
chk "reject: evidence outside .claude/claudehut/" '! cs --session s set-review pass --evidence "$W/bad-review.md" 2>/dev/null'
printf '{"file":"src/main/java/U.java","kind":"duplicate"}\n' > "$P/.claude/claudehut/state/0001-x.suspects.jsonl"
printf '# Review\n| x | ✓ satisfied | A.java:1 |\n./gradlew test — 12 passed\n' > "$ev"
chk "reject: a staged reuse suspect not resolved in review.md" '! cs --session s set-review pass --evidence "$ev" 2>/dev/null'
printf '| src/main/java/U.java | ✓ satisfied resolved | U.java:3 |\n' >> "$ev"
chk "set-review pending needs no evidence" 'cs --session s set-review pending 2>/dev/null && jq -e ".review==\"pending\"" "$TD/task.json" >/dev/null'
chk "accept: valid review.md → review=pass + review_evidence in task.json" 'cs --session s set-review pass --evidence "$ev" 2>/dev/null && jq -e ".review==\"pass\" and (.review_evidence|type==\"string\")" "$TD/task.json" >/dev/null'

echo "== doclint-advise: advisory lint of a task artifact after Write|Edit (06 §4, AC-10) =="
P="$(new_plane da)"; mk_task "$P" S 0001-x full false; DT="$P/.claude/claudehut/tasks/0001-x"
dpl() { jq -nc --arg f "$1" '{session_id:"S",hook_event_name:"PostToolUse",tool_name:"Write",tool_input:{file_path:$f}}'; }
mkdir -p "$P/src/main/java"; printf 'class Foo {}\n' > "$P/src/main/java/Foo.java"
run_hook doclint-advise "$P" "$(dpl "$P/src/main/java/Foo.java")"
chk "doclint-advise: a Write to src/main/java/Foo.java is silent, exit 0" 'silent'
printf '%s\n' "$EXSPEC" > "$DT/spec.md"
printf '%s\n' "$EXPLAN" | awk '/^## 2\. Design/{print; print "```java"; print "class X {}"; print "```"; next} 1' > "$DT/plan.md"
h0="$(fsum "$P/.claude/claudehut")"
run_hook doclint-advise "$P" "$(dpl "$DT/plan.md")"
chk "doclint-advise: a plan.md with a blocking violation → one PostToolUse additionalContext naming it, ≤500 chars" \
  'one_ctx PostToolUse && ctx | grep -q "plan.md" && [ "$(ctx | wc -l | tr -d " ")" -le 10 ] && [ "$(ctx | wc -m | tr -d " ")" -le 500 ]'
chk "doclint-advise: writes nothing to the plane (K8)" '[ "$(fsum "$P/.claude/claudehut")" = "$h0" ]'
printf '%s\n' "$EXPLAN" > "$DT/plan.md"
run_hook doclint-advise "$P" "$(dpl "$DT/plan.md")"
chk "doclint-advise: the clean template example is silent" 'silent'
printf 'scratch\n' > "$DT/notes.md"
run_hook doclint-advise "$P" "$(dpl "$DT/notes.md")"
chk "doclint-advise: a non-artifact file in the task dir is silent" 'silent'
printf '%s\n' "$EXPLAN" | awk '/^## 2\. Design/{print; print "```java"; print "class X {}"; print "```"; next} 1' > "$DT/plan.md"
run_hook doclint-advise "$P" "$(dpl "$DT/plan.md")" DOCLINT_TEMPLATES="$W/no-templates"
chk "doclint-advise: a missing template is silent (advise mode never fails)" 'silent'
# M3 backlog: a hung engine is killed at DOCLINT_ADVISE_TIMEOUT (default 3 s) — silent, exit 0, nothing logged
mkdir -p "$W/dla-scripts"; cp -R "$ROOT/scripts/." "$W/dla-scripts/"; printf '#!/usr/bin/env bash\nsleep 20\n' > "$W/dla-scripts/doclint.sh"
: > "$P/.claude/claudehut/state/hook-errors.log"; t0="$(date +%s)"
OUT="$(printf '%s' "$(dpl "$DT/plan.md")" | CLAUDE_PROJECT_DIR="$P" DOCLINT_ADVISE_TIMEOUT=1 bash "$W/dla-scripts/doclint-advise.sh" 2>/dev/null)"; RC=$?
chk "doclint-advise: a hung engine is killed at DOCLINT_ADVISE_TIMEOUT — silent, exit 0, <5 s, no hook error" \
  '[ "$RC" = 0 ] && silent && [ $(( $(date +%s) - t0 )) -lt 5 ] && errlog_empty "$P"'

echo "== claudehut-state: set-plan smart gate on the full route (kept; route replaces tier) =="
P="$(new_plane pg)"; cs() { CLAUDE_PROJECT_DIR="$P" "$ST" "$@"; }   # a fresh task: the one above passed review (finished)
cs --session s start --route full --slug x >/dev/null 2>&1; TD="$P/.claude/claudehut/tasks/0001-x"
# M3 (06 §8): the sensitive trigger is a T-row's Files cell (3rd column), so the changelog path goes there.
printf '%s\n' "$EXSPEC" > "$TD/spec.md"
printf '%s\n' "$EXPLAN" | sed 's#src/main/java/app/order/OrderMetrics.java#src/main/resources/db/changelog.xml#' > "$TD/plan.md"
chk "a sensitive full-route plan needs a plan-reviewer APPROVE" '! cs --session s set-plan .claude/claudehut/tasks/0001-x/plan.md 2>"$W/pg.err" && grep -q "needs a plan-reviewer APPROVE" "$W/pg.err"'
printf '%s\n' "$EXPR" > "$TD/plan-review.md"
cs --session s set-plan-review APPROVE --evidence .claude/claudehut/tasks/0001-x/plan-review.md 2>/dev/null
chk "APPROVE of the same bytes unblocks set-plan; plan_review_round counts reviews" 'cs --session s set-plan .claude/claudehut/tasks/0001-x/plan.md 2>/dev/null && jq -e ".plan_approved==true and .plan_review_round==1" "$TD/task.json" >/dev/null'
printf '<!-- edited after the review -->\n' >> "$TD/plan.md"
chk "an edit after the APPROVE is caught by the content hash" '! cs --session s set-plan .claude/claudehut/tasks/0001-x/plan.md 2>"$W/pg.err" && grep -q "content hash mismatch" "$W/pg.err"'
cs --session s set-route light 2>/dev/null
# L1 (06 §6): the artifact header follows the task's route, so the change is recorded in the plan too.
sed -i.bak 's/route: full · rev/route: light · rev/' "$TD/plan.md" && rm -f "$TD/plan.md.bak"
chk "the way out of the gate is a route change, not a bypass (light: structure only)" 'cs --session s set-plan .claude/claudehut/tasks/0001-x/plan.md 2>/dev/null'
chk "canon: a traversal artifact path is rejected" '! cs --session s set-spec ".claude/claudehut/../../src/main/Evil.md" 2>/dev/null'

echo "== claudehut-state: cost-report (read-only; task~ from the schema-2 pointer) =="
P="$(new_plane cr)"; LD="$P/.claude/claudehut/ledger"; mkdir -p "$LD" "$P/.claude/claudehut/state"
{ printf '{"ts":"2026-08-17T10:00:00Z","event":"start","session_id":"s","agent_id":"a1","agent_type":"claudehut:claudehut-reviewer","cwd":"/p"}\n'
  printf '{"ts":"2026-08-17T10:00:07Z","event":"stop","session_id":"s","agent_id":"a1","agent_type":"claudehut:claudehut-reviewer","effort":"high"}\n'
  printf '{"ts":"2026-08-17T10:05:00Z","event":"stop","session_id":"s","agent_id":"ORPHAN","agent_type":""}\n'
  printf '{ torn\n'; } > "$LD/dispatches.jsonl"
printf '{"schema":2,"active_task":"0042-cost"}\n' > "$P/.claude/claudehut/state/s.json"
LB="$(shasum "$LD/dispatches.jsonl")"
CR="$(CLAUDE_PROJECT_DIR="$P" "$ST" cost-report 2>/dev/null)"
case "$CR" in *"1 dispatch(es) paired on agent_id; 1 orphan stop(s) DISCARDED"*) ok "cost-report: joins on agent_id, discards the orphan, survives a torn line" ;; *) bad "cost-report pairing" ;; esac
case "$CR" in *"0042-cost~"*) ok "cost-report: task~ resolves from the schema-2 active_task pointer" ;; *) bad "cost-report: task~ not resolved from active_task" ;; esac
chk "cost-report: read-only (ledger byte-identical, no --session needed)" '[ "$(shasum "$LD/dispatches.jsonl")" = "$LB" ] && [ "$(CLAUDE_PROJECT_DIR="$P" "$ST" cost-report --count 2>/dev/null)" = 1 ]'
mkdir -p "$P/.claude/claudehut/tasks/0042-cost"
printf '{"schema":2,"id":"0042-cost","session":"s","status":"done","created":"2026-08-17T09:00:00Z"}\n' > "$P/.claude/claudehut/tasks/0042-cost/task.json"
printf '{"schema":2,"active_task":null}\n' > "$P/.claude/claudehut/state/s.json"   # what `end --status done` leaves
mkdir -p "$P/.claude/claudehut/tasks/0043-bad"; printf '{ corrupt\n' > "$P/.claude/claudehut/tasks/0043-bad/task.json"   # costs only itself
CR="$(CLAUDE_PROJECT_DIR="$P" "$ST" cost-report 2>/dev/null)"
case "$CR" in *"0042-cost~"*) ok "cost-report: after end (pointer null), task~ still resolves from task.json .session, a corrupt task.json beside it notwithstanding (R2-2)" ;; *) bad "cost-report: task~ unresolved after end (R2-2)" ;; esac

echo "== AC7: grep every captured hook output =="
chk "AC7: $N_RUNS hook runs — zero permissionDecision / \"decision\" / updatedInput / \"continue\"" \
  '! grep -qE "permissionDecision|\"decision\"|updatedInput|\"continue\"" "$CORPUS"'
chk "AC6: $N_RUNS hook runs — zero contract violations (exit≠0, >1 object, invalid JSON)" '[ "$N_CONTRACT_BAD" = 0 ]'

# The regression suites (other state-writer and script regressions) run after the contract + behavior core.
# Each runs as its own process; its "N passed, M failed" line is folded into this suite's totals.
if [ "$FAST" = 0 ]; then
  for rs in state-tests script-tests doclint-tests review-pack-tests; do
    f="$ROOT/evals/regress/$rs.sh"; [ -f "$f" ] || { bad "regress/$rs.sh is missing (expected regression suite)"; continue; }
    echo "== regress/$rs.sh =="
    ro="$(EVAL_COUNT_DIR= REVIEW_PACK_NO_MUTANTS=1 bash "$f" 2>&1)"; rr=$?   # rule-removal mutants: run the suite alone
    # Echoed with "N passed" reworded, so this suite's own HOOK-TESTS line stays the only "N passed" on stdout
    # (reference-check.sh's standalone fallback reads the first one).
    printf '%s\n' "$ro" | sed -E 's/([0-9]+) passed/\1 ok/g'
    np="$(printf '%s\n' "$ro" | grep -oE '[0-9]+ passed, [0-9]+ failed' | tail -1)"
    if [ -n "$np" ]; then
      PASS=$((PASS + ${np%% passed*})); nf="${np#*passed, }"; FAIL=$((FAIL + ${nf%% failed*}))
      [ "$rr" = 0 ] || [ "${nf%% failed*}" != 0 ] || bad "regress/$rs.sh exited $rr with 0 failures reported"
    else
      bad "regress/$rs.sh printed no 'N passed, M failed' line (exit $rr)"
    fi
  done
fi

# The count is the number of assertions of the DEFAULT run (README pins it); --fast publishes none.
[ "$FAST" = 0 ] && [ -n "${EVAL_COUNT_DIR:-}" ] && printf '%s\n' "$PASS" > "$EVAL_COUNT_DIR/hook-tests.count"
echo; echo "HOOK-TESTS$([ "$FAST" = 1 ] && echo " (--fast)"): $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
