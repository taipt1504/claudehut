#!/usr/bin/env bash
# state-tests.sh — standalone regression tests for bin/claudehut-state task-lifecycle fixes:
#   V3-2   task numbering past 9999 stays unique (numeric max, any digit count)
#   R3-C2  a DONE task refuses a new request's review verbs (set-phase review, set-outstanding,
#          set-review pass with evidence outside its own dir) — no-op + notice, task.json byte-identical
#   V3-6   one shape-change rule: after findings, set-profile/set-route are no-op + notice and
#          `start --profile <new>` opens the new task; CLI and both skills say the same
#   M2     legacy verbs (04 §3): the removed ones are no-op + notice (exit 0, nothing written, even with a task
#          open), set-complexity is a deprecated route alias, and the CLI header records why each is kept
# Self-contained temp planes, no network, < 60 s. Prints "STATE-TESTS: N passed, M failed"; exit 1 on failure.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CS="${STATE_BIN:-$ROOT/bin/claudehut-state}"
command -v jq >/dev/null 2>&1 || { echo "STATE-TESTS: jq missing"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/state-tests.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "ok - $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL - $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

newplane() { local p="$TMP/$1"; mkdir -p "$p/.claude/claudehut/tasks"; printf '%s' "$p"; }
cs() { local p="$1" s="$2"; shift 2; CLAUDE_PROJECT_DIR="$p" "$CS" --session "$s" "$@"; }
tj() { cat "$1/.claude/claudehut/tasks/$2/task.json"; }

write_review() { # $1 abs path
  mkdir -p "$(dirname "$1")"
  cat >"$1" <<'EOF'
# Review
| Item | Verdict | Locus |
|------|---------|-------|
| AC-001 | ✓ satisfied | Foo.java:42 |

./gradlew test — 12 passed
EOF
}
write_findings() { mkdir -p "$(dirname "$1")"; printf '# Findings\n\nAnswer: Foo.java:1\n' >"$1"; }

# ── V3-2: numbering past 9999 ─────────────────────────────────────────────────────────────────────────────
P="$(newplane num)"; mkdir -p "$P/.claude/claudehut/tasks/9999-x"
a="$(cs "$P" r1 start --route light --slug a 2>/dev/null | head -1)"
b="$(cs "$P" r2 start --route light --slug b 2>/dev/null | head -1)"
check "V3-2: first task past 9999 is 10000 (got $a)" '[ "$a" = "10000-a" ]'
check "V3-2: next task past 10000 gets a new number (got $b)" '[ "$b" = "10001-b" ]'
nums="$(ls -1 "$P/.claude/claudehut/tasks" | sed 's/-.*//' | sort | uniq -d)"
check "V3-2: no two task dirs share a number" '[ -z "$nums" ]'

# ── R3-C2: review verbs on a DONE task ────────────────────────────────────────────────────────────────────
P="$(newplane done)"
id="$(cs "$P" sA start --route light --slug two 2>/dev/null | head -1)"
write_review "$P/.claude/claudehut/tasks/$id/review.md"
cs "$P" sA set-review pass --evidence ".claude/claudehut/tasks/$id/review.md" 2>/dev/null
check "R3-C2 control: own-evidence set-review pass records" '[ "$(tj "$P" "$id" | jq -r .review)" = pass ]'
before="$(tj "$P" "$id")"
write_review "$P/.claude/claudehut/tasks/tmp3/review.md"
e1="$(cs "$P" sA set-phase review 2>&1)"; r1=$?
e2="$(cs "$P" sA set-outstanding '["x"]' 2>&1)"; r2=$?
e3="$(cs "$P" sA set-review pass --evidence .claude/claudehut/tasks/tmp3/review.md 2>&1)"; r3=$?
e4="$(cs "$P" sA set-review pending 2>&1)"; r4=$?
check "R3-C2: blocked review verbs exit 0" '[ "$r1$r2$r3$r4" = 0000 ]'
check "R3-C2: set-phase review on a done task prints the finished notice" 'grep -q "already finished" <<<"$e1"'
check "R3-C2: set-outstanding on a done task prints the finished notice" 'grep -q "already finished" <<<"$e2"'
check "R3-C2: set-review pass with foreign evidence prints the finished notice" 'grep -q "already finished" <<<"$e3"'
check "R3-C2: done task stays byte-identical after a new request's review verbs" '[ "$(tj "$P" "$id")" = "$before" ]'
cs "$P" sA set-phase learn 2>/dev/null
check "R3-C2 control: set-phase learn still records on a done task" '[ "$(tj "$P" "$id" | jq -r .phase)" = learn ]'

# ── V3-6: shape change after findings → new task via start ────────────────────────────────────────────────
P="$(newplane shape)"
id="$(cs "$P" sB start --route light --profile investigation --slug q 2>/dev/null | head -1)"
write_findings "$P/.claude/claudehut/tasks/$id/findings.md"
cs "$P" sB set-findings ".claude/claudehut/tasks/$id/findings.md" 2>/dev/null
before="$(tj "$P" "$id")"
e1="$(cs "$P" sB set-profile bugfix 2>&1)"; r1=$?
e2="$(cs "$P" sB set-route full 2>&1)"; r2=$?
e3="$(cs "$P" sB set-complexity full 2>&1)"; r3=$?
check "V3-6: shape-change verbs on a findings task exit 0" '[ "$r1$r2$r3" = 000 ]'
check "V3-6: set-profile on a findings task is a no-op + notice" 'grep -q "already finished" <<<"$e1" && grep -q "start" <<<"$e1"'
check "V3-6: set-route on a findings task is a no-op + notice" 'grep -q "already finished" <<<"$e2"'
check "V3-6: findings task stays byte-identical (profile investigation, route light)" '[ "$(tj "$P" "$id")" = "$before" ]'
# the review OF the findings still records on the findings task
write_review "$P/.claude/claudehut/tasks/$id/review.md"
cs "$P" sB set-outstanding '[]' 2>/dev/null
check "V3-6 control: set-outstanding (review of findings) still records" '[ "$(tj "$P" "$id" | jq -c .outstanding)" = "[]" ]'
id2="$(cs "$P" sB start --route light --profile bugfix --slug fix 2>/dev/null | head -1)"
check "V3-6: start --profile bugfix opens a new task" '[ -n "$id2" ] && [ "$id2" != "$id" ] && [ "$(tj "$P" "$id2" | jq -r .profile)" = bugfix ]'
check "V3-6: the findings task closes as done with its profile unchanged" \
  '[ "$(tj "$P" "$id" | jq -r .status)" = done ] && [ "$(tj "$P" "$id" | jq -r .profile)" = investigation ]'
cs "$P" sB set-profile feature 2>/dev/null
check "V3-6 control: set-profile mid-flow on an open unfinished task records" '[ "$(tj "$P" "$id2" | jq -r .profile)" = feature ]'

# ── V3-6: CLI and both skills state the same rule ─────────────────────────────────────────────────────────
WF="$ROOT/skills/claudehut-workflow/SKILL.md"; DG="$ROOT/skills/claudehut-workflow/references/digest.md"
DS="$ROOT/skills/discover/SKILL.md"
for f in "$WF" "$DG"; do
  check "V3-6 doc: ${f#"$ROOT"/} says a shape change after it finished is start --profile <new>" \
    'tr "\n" " " <"$f" | grep -qE "after it finished.{0,120}start --profile <new>"'
done
check "V3-6 doc: discover treats a findings_path task as a previous request's (start a new one)" \
  'tr "\n" " " <"$DS" | grep -qE "findings_path. set: that is a previous request.s.{0,80}start"'
check "V3-6 doc: CLI header names the shape change as a new request" 'grep -q "shape change via set-profile/set-route" "$CS"'

# ── M2: legacy verbs — kept, per the "Legacy verbs" decision in the CLI header ─────────────────────────────
P="$(newplane legacy)"
id="$(cs "$P" sL start --route light --slug lg 2>/dev/null | head -1)"
before="$(tj "$P" "$id")"; ptr="$(cat "$P/.claude/claudehut/state/sL.json")"
lr=0; for v in "set-bypass true --reason x" "mark-skill implement" "pause" "rename x" "route --confirmed full"; do
  # shellcheck disable=SC2086
  e="$(cs "$P" sL $v 2>&1)" || lr=1
  grep -q "removed in v0.12" <<<"$e" || lr=1
done
check "M2: removed verbs (set-bypass mark-skill pause rename route) exit 0 with a 'removed in v0.12' notice" '[ "$lr" = 0 ]'
check "M2: removed verbs leave the open task and the session pointer byte-identical" \
  '[ "$(tj "$P" "$id")" = "$before" ] && [ "$(cat "$P/.claude/claudehut/state/sL.json")" = "$ptr" ]'
e="$(cs "$P" sL set-complexity full 2>&1)"; r=$?
check "M2: set-complexity is a deprecated alias — notice says deprecated, the route becomes full" \
  '[ "$r" = 0 ] && grep -q deprecated <<<"$e" && [ "$(tj "$P" "$id" | jq -r .route)" = full ]'
check "M2 doc: the CLI header records the legacy-verb decision (set-profile live, the rest kept until M7)" \
  'grep -q "Legacy verbs — M2 decision" "$CS" && grep -q "set-profile     a LIVE verb" "$CS"'

echo "STATE-TESTS: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
