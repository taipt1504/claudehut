#!/usr/bin/env bash
# state-diff-tests.sh — differential test of the two state writers (0.20 M1 strangler, docs/v0.20 04 §7).
# The same verb scripts run through the Python writer (claudehut_kernel/state.py) and the 0.12 bash writer
# (scripts/legacy/claudehut-state.sh) on identical fixture repos. Per scenario the transcripts must be identical:
# every command's exit code, stdout and stderr, then every task.json and state pointer (timestamps and the review
# binding's time masked, the fixture path replaced by <P>). The suites assert a subset of the messages; this catches
# drift in the rest. Since M1b-b the Python writer also keeps the event log as the source of truth: its state events
# (and task.json's event_rev) have no bash counterpart, so they are left out of the comparison and checked on their
# own — every Python run is under CLAUDEHUT_STATE_SELFCHECK=1 and each task must replay to its task.json.
# Prints "STATE-DIFF: N passed, M failed"; exit 1 on failure.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CS="$ROOT/bin/claudehut-state"
command -v jq >/dev/null 2>&1 || { echo "STATE-DIFF: jq missing"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "STATE-DIFF: python3 missing — nothing to compare"; echo "STATE-DIFF: 0 passed, 0 failed"; exit 0; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/state-diff.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
export CLAUDEHUT_HOST_PROBE=0 CLAUDEHUT_GATE_MODE=warn

# A stub doclint: a file containing BLOCKME is a structural violation; every check prints an over-budget total.
STUB="$TMP/doclint-stub.sh"
cat >"$STUB" <<'EOF'
#!/usr/bin/env bash
f="${@: -1}"
echo "budget: total 120/100 words"
if grep -q BLOCKME "$f" 2>/dev/null; then echo "L1 blocking: stub violation"; exit 1; fi
exit 0
EOF

fixture() { # $1 dir → a git repo with a legacy plane, one commit
  mkdir -p "$1/.claude/claudehut/tasks" "$1/src/main/java/demo"
  printf 'package demo;\npublic class Account {\n  String holder;\n}\n' >"$1/src/main/java/demo/Account.java"
  git -C "$1" init -q && git -C "$1" -c user.email=e@e -c user.name=e add -A \
    && GIT_AUTHOR_DATE=2026-01-01T00:00:00Z GIT_COMMITTER_DATE=2026-01-01T00:00:00Z \
       git -C "$1" -c user.email=e@e -c user.name=e commit -qm base   # fixed dates: the same base sha in both runs
}

# Each scenario is a list of lines: "<session>|<args…>" (args split on spaces; @F@ = the task dir rel path of the
# session's current task, written by `w`), or "!<shell>" run in the fixture (writes artifacts), with $T = task dir.
run_scenario() { # $1 impl  $2 dir  $3 scenario file → transcript on stdout
  local impl="$1" P="$2" line sid rest out err rc T tid
  fixture "$P"
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    tid="$(ls -1 "$P/.claude/claudehut/tasks" 2>/dev/null | sort | tail -1)"; T=".claude/claudehut/tasks/$tid"
    case "$line" in
      '#'*) continue ;;
      '!'*) ( cd "$P" && T="$T" bash -c "${line#!}" ) ; continue ;;
    esac
    sid="${line%%|*}"; rest="${line#*|}"; rest="${rest//@T@/$T}"
    # shellcheck disable=SC2086
    if [ "$sid" = "-" ]; then
      out="$(cd "$P" && CLAUDE_PROJECT_DIR="$P" CLAUDEHUT_STATE_IMPL="$impl" CLAUDEHUT_STATE_SELFCHECK=1 CLAUDEHUT_DOCLINT="$STUB" "$CS" $rest 2>"$TMP/err")"; rc=$?
    else
      out="$(cd "$P" && CLAUDE_PROJECT_DIR="$P" CLAUDEHUT_STATE_IMPL="$impl" CLAUDEHUT_STATE_SELFCHECK=1 CLAUDEHUT_DOCLINT="$STUB" "$CS" --session "$sid" $rest 2>"$TMP/err")"; rc=$?
    fi
    err="$(cat "$TMP/err")"
    printf '$ [%s] %s\nrc=%s\n--out\n%s\n--err\n%s\n' "$sid" "$rest" "$rc" "$out" "$err"
  done <"$3"
  echo "== state"
  for f in "$P"/.claude/claudehut/tasks/*/task.json "$P"/.claude/claudehut/state/*.json; do
    [ -f "$f" ] || continue
    echo "-- ${f#"$P"/}"
    jq -S 'del(.event_rev) | walk(if type=="object" then with_entries(if (.key|test("^(created|updated|ended|at|plan_review_user_decision_at)$")) then .value="<ts>" else . end) else . end)' "$f" 2>/dev/null || cat "$f"
  done
  echo "== events"
  for f in "$P"/.claude/claudehut/tasks/*/events.jsonl; do
    [ -f "$f" ] || continue
    # gate.* and budget.exceeded are written by both; the state events (rev) only by the Python writer, and the
    # informational review.verdict / task.ended lines only by the bash writer's gate CLI.
    ev="$(jq -c 'select(has("rev") | not) | select(.type != "review.verdict" and .type != "task.ended") | del(.ts)' "$f" 2>/dev/null)"
    [ -z "$ev" ] || printf -- '-- %s\n%s\n' "${f#"$P"/}" "$ev"
  done
}

compare() { # $1 name  $2 scenario text
  local name="$1" sc="$TMP/$1.sc" a b
  printf '%s\n' "$2" >"$sc"
  a="$TMP/$name-py"; b="$TMP/$name-bash"
  run_scenario py "$a/P" "$sc" | sed "s#$a/P#<P>#g; s#$(cd "$a" 2>/dev/null && pwd -P)/P#<P>#g" >"$TMP/$name.py.txt"
  run_scenario bash "$b/P" "$sc" | sed "s#$b/P#<P>#g; s#$(cd "$b" 2>/dev/null && pwd -P)/P#<P>#g" >"$TMP/$name.bash.txt"
  local td bad=""
  for td in "$a"/P/.claude/claudehut/tasks/*/; do
    "$ROOT/bin/claudehut-kernel" replay --task "$td" --check 2>/dev/null || bad="$bad ${td%/}"
  done
  if [ -n "$bad" ]; then
    FAIL=$((FAIL+1)); echo "FAIL - $name: the event log does not replay to task.json for:${bad//$a\/P\//}"
  else
    PASS=$((PASS+1)); echo "ok - $name: every task's event log replays to its task.json"
  fi
  if diff -u "$TMP/$name.bash.txt" "$TMP/$name.py.txt" >"$TMP/$name.diff"; then
    PASS=$((PASS+1)); echo "ok - $name: identical transcripts ($(grep -c '^\$ ' "$TMP/$name.py.txt") commands)"
  else
    FAIL=$((FAIL+1)); echo "FAIL - $name: transcripts differ (bash → py)"; head -40 "$TMP/$name.diff"
  fi
}

REVIEW_OK='printf "# Review\n| Item | Verdict | Locus |\n|---|---|---|\n| AC-1 | ✓ satisfied | src/main/java/demo/Account.java:3 |\n\n./gradlew test — 3 passed\n" > $T/review.md'

compare light-lifecycle "
s1|start --route light --slug Héllo World__X!! --profile feature
s1|status
s1|set-phase spec
!printf '# Spec\n> rev: 1\n' > \$T/spec.md
s1|set-spec @T@/spec.md
s1|set-phase plan --task 9999-other
!printf '# Task\n## Approach\nx\n' > \$T/task.md
s1|set-plan @T@/task.md
s1|set-enforcement --skills a,b --rules
s1|set-outstanding not-json
s1|set-outstanding [\"x\",1]
s1|set-review pending
s1|set-review pass
s1|set-review pass --evidence src/main/java/demo/Account.java
!printf '# Review\nno table\n' > \$T/review.md
s1|set-review pass --evidence @T@/review.md
!$REVIEW_OK
s1|set-review pass --evidence @T@/review.md
s1|set-spec @T@/spec.md
s1|set-phase discover
s1|end --status done
s1|status"

compare full-plan-review "
s2|start --route full --slug plan-cap --profile migration
!printf '| T-1 | a | src/auth/X.java |\n' > \$T/plan.md
s2|set-plan @T@/plan.md
!printf 'Verdict: REVISE\n' > \$T/plan-review.md
s2|set-plan-review APPROVE --evidence @T@/plan-review.md
s2|set-plan-review REVISE --evidence @T@/plan-review.md
s2|set-plan-review REVISE --evidence @T@/plan-review.md
s2|set-plan-review REVISE --evidence @T@/plan-review.md
s2|set-plan-review APPROVE --evidence @T@/plan-review.md --user-decision go ahead
!printf '**Verdict:** approve\n' > \$T/plan-review.md
s2|set-plan-review APPROVE --evidence @T@/plan-review.md
s2|set-plan @T@/plan.md
!printf '| T-1 | a | src/auth/X.java |\n| T-2 | b | c |\n' > \$T/plan.md
s2|set-plan @T@/plan.md
s2|set-route light
s2|set-plan @T@/task.md
s2|set-complexity huge
s2|set-complexity full
s2|set-profile nope
s2|set-profile bugfix
s2|set-tier T5
s2|set-tier T2 --reason new provider family
s2|set-tier T1
s2|set-tier T1 --user-decision ok, it is only a rename
s2|status"

compare sessions-and-resume "
s3|set-phase spec
s3|start --route light --slug one
s4|resume 0001-one
s3|set-phase spec
s3|end --status done
s4|set-phase implement
s4|start --route light --slug two
s4|resume 0001-one
s4|end --status abandoned
s4|resume 0001-one
s4|resume ../x
-|set-phase discover
-|--session set-phase discover
s5|--session
s5|bogus-verb
s5|set-bypass
s5|mark-skill
s5|pause
s5|status"

compare artifacts-and-gates "
s6|start --route light --slug art
s6|set-reuse-scan
s6|set-reuse-scan --artifact docs/x.md
!printf '| Dimension | Asset |\n' > \$T/reuse-scan.md
s6|set-reuse-scan --artifact @T@/reuse-scan.md
!printf '| Dimension | Existing asset | Decision | Fit | Impact |\n| x | y | adopt | ok | low |\n' > \$T/reuse-scan.md
s6|set-reuse-scan --artifact @T@/reuse-scan.md
!printf 'BLOCKME\n' > \$T/brainstorm.md
s6|set-brainstorm @T@/brainstorm.md
s6|set-brainstorm @T@/missing.md
!printf 'plain\n' > \$T/findings.md
s6|set-findings @T@/findings.md
!$REVIEW_OK
!printf '{\"file\":\"src/main/java/demo/Account.java\"}\n' > .claude/claudehut/state/\$(basename \$T).suspects.jsonl
s6|set-review pass --evidence @T@/review.md
!printf '# Review\n| Item | Verdict | Locus |\n|---|---|---|\n| AC-1 | ✓ satisfied | src/main/java/demo/Account.java:3 resolved |\n\n./gradlew test — 3 passed\n' > \$T/review.md
s6|set-review pass --evidence @T@/review.md
!printf '# Findings\n' > \$T/findings.md
s6|set-findings @T@/findings.md
s6|set-review capped
s6|set-outstanding []
s6|end --status maybe
s6|end --status done"

echo "STATE-DIFF: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
