#!/usr/bin/env bash
# state-tests.sh — standalone regression tests for bin/claudehut-state task-lifecycle fixes:
#   V3-2   task numbering past 9999 stays unique (numeric max, any digit count)
#   R3-C2  a DONE task refuses a new request's review verbs (set-phase review, set-outstanding,
#          set-review pass with evidence outside its own dir) — no-op + notice, task.json byte-identical
#   V3-6   one shape-change rule: after findings, set-profile/set-route are no-op + notice and
#          `start --profile <new>` opens the new task; CLI and both skills say the same
#   M2     legacy verbs (04 §3): the removed ones are no-op + notice (exit 0, nothing written, even with a task
#          open), set-complexity is a deprecated route alias, and the CLI header records why each is kept
#   M3     doclint gate (06 §4, §8): set-spec/set-brainstorm/set-plan/set-plan-review/set-phase --spec refuse on a
#          blocking violation with task.json byte-identical, pass (and print) on advisory; plan-review Verdict must
#          match; round cap 2 → --user-decision; light set-plan takes task.md; doc_schema:2 stamped at start.
#          A stub engine (CLAUDEHUT_DOCLINT) keeps these independent of the rule set; one check uses the real one.
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

# ── M3: doclint gate — a stub engine: "BLOCKME" → a blocking line + exit 1, "ADVISE" → an advisory line + exit 0 ──
STUB="$TMP/doclint-stub.sh"
cat >"$STUB" <<'STUBEOF'
#!/usr/bin/env bash
f="${!#}"; printf '%s\n' "$*" >>"${STUB_LOG:-/dev/null}"
if grep -q BLOCKME "$f"; then echo "L4 blocking Tasks: stub structural violation"; exit 1; fi
grep -q ADVISE "$f" && echo "L9 advisory Decisions: cell Decision — 120w/80w (budget)"
exit 0
STUBEOF
export STUB_LOG="$TMP/stub.log"
dcs() { CLAUDEHUT_DOCLINT="$STUB" cs "$@"; }
P="$(newplane dl)"
id="$(dcs "$P" sD start --route full --profile feature --slug dl 2>/dev/null | head -1)"; D="$P/.claude/claudehut/tasks/$id"; R=".claude/claudehut/tasks/$id"
check "M3: start stamps doc_schema:2 (and plan_review_round:0)" '[ "$(tj "$P" "$id" | jq -c "[.doc_schema,.plan_review_round]")" = "[2,0]" ]'
printf '# Spec\nBLOCKME\n' >"$D/spec.md"; before="$(tj "$P" "$id")"
e="$(dcs "$P" sD set-spec "$R/spec.md" 2>&1)"; r=$?
check "M3: set-spec on a blocking violation exits 1, prints the violation line" '[ "$r" = 1 ] && grep -q "L4 blocking Tasks" <<<"$e" && grep -q "spec rejected" <<<"$e"'
check "M3: a refused set-spec leaves task.json byte-identical" '[ "$(tj "$P" "$id")" = "$before" ]'
check "M3: the gate passes kind, route and profile to the engine" 'grep -q -- "--kind spec --route full --profile feature" "$STUB_LOG"'
e="$(dcs "$P" sD set-phase implement --spec "$R/spec.md" 2>&1)"; r=$?
check "M3: set-phase --spec runs the same gate (no bypass): refused, task.json unchanged" '[ "$r" = 1 ] && [ "$(tj "$P" "$id")" = "$before" ]'
printf '# Spec\nADVISE\n' >"$D/spec.md"
e="$(dcs "$P" sD set-spec "$R/spec.md" 2>&1)"; r=$?
check "M3: set-spec with only advisory results records and prints the budget line" '[ "$r" = 0 ] && grep -q "120w/80w" <<<"$e" && [ "$(tj "$P" "$id" | jq -r .spec_path)" = "$R/spec.md" ]'
before="$(tj "$P" "$id")"
e="$(dcs "$P" sD set-spec "$R/nope.md" 2>&1)"; r=$?
check "M3: set-spec of a missing file is refused, nothing written" '[ "$r" = 1 ] && [ "$(tj "$P" "$id")" = "$before" ]'
printf '# B\nBLOCKME\n' >"$D/brainstorm.md"
check "M3: set-brainstorm refuses on a blocking violation" '! dcs "$P" sD set-brainstorm "$R/brainstorm.md" 2>/dev/null && [ -z "$(tj "$P" "$id" | jq -r ".brainstorm_path // empty")" ]'
e="$(CLAUDEHUT_DOCLINT="$TMP/absent.sh" cs "$P" sD set-spec "$R/spec.md" 2>&1)"; r=$?
check "M3: a missing engine is not a pass on a doc_schema-2 task (exit 1, names the engine path)" '[ "$r" = 1 ] && grep -q "absent.sh" <<<"$e"'

# plan-review: verdict match, round cap 2, --user-decision
printf '# Plan review\nVerdict: REVISE\n## Findings\n' >"$D/plan-review.md"
e="$(dcs "$P" sD set-plan-review APPROVE 2>&1)"; r=$?
check "M3: set-plan-review APPROVE against 'Verdict: REVISE' is refused (default evidence = the task's plan-review.md)" '[ "$r" = 1 ] && grep -q "Verdict: REVISE" <<<"$e" && [ "$(tj "$P" "$id" | jq -r .plan_review_round)" = 0 ]'
dcs "$P" sD set-plan-review REVISE 2>/dev/null; e="$(dcs "$P" sD set-plan-review REVISE 2>&1)"; r=$?
check "M3: two REVISE rounds record (round 2) and the second one announces the cap" '[ "$r" = 0 ] && [ "$(tj "$P" "$id" | jq -r .plan_review_round)" = 2 ] && grep -q "AskUserQuestion" <<<"$e"'
before="$(tj "$P" "$id")"; printf '# Plan review\nVerdict: APPROVE\n## Findings\n' >"$D/plan-review.md"
e="$(dcs "$P" sD set-plan-review APPROVE 2>&1)"; r=$?
check "M3: a third round without --user-decision is refused as capped, task.json unchanged" '[ "$r" = 1 ] && grep -q capped <<<"$e" && grep -q -- "--user-decision" <<<"$e" && [ "$(tj "$P" "$id")" = "$before" ]'
dcs "$P" sD set-plan-review APPROVE --user-decision "owner: ship with the MED finding open" 2>/dev/null
check "M3: --user-decision stores the text, resets the round to 0 and records the verdict" \
  '[ "$(tj "$P" "$id" | jq -c "[.plan_review,.plan_review_round,.plan_review_user_decision]")" = "[\"APPROVE\",0,\"owner: ship with the MED finding open\"]" ]'
printf '# Plan review\nBLOCKME\nVerdict: APPROVE\n' >"$D/plan-review.md"; before="$(tj "$P" "$id")"
check "M3: set-plan-review refuses a plan-review.md with a blocking violation" '! dcs "$P" sD set-plan-review APPROVE 2>/dev/null && [ "$(tj "$P" "$id")" = "$before" ]'

# set-plan: blocking refuses; the smart gate reads the Files cell, not prose (06 AC12)
printf '# Plan\nBLOCKME\n| T-001 | AC-001 | src/a.java | t |\n' >"$D/plan.md"
check "M3: set-plan refuses on a blocking violation (plan_approved stays false)" '! dcs "$P" sD set-plan "$R/plan.md" 2>/dev/null && [ "$(tj "$P" "$id" | jq -r .plan_approved)" = false ]'
P2="$(newplane dl2)"; id2="$(dcs "$P2" sE start --route full --profile feature --slug p 2>/dev/null | head -1)"; D2="$P2/.claude/claudehut/tasks/$id2"; R2=".claude/claudehut/tasks/$id2"
{ printf '# Plan\n## 5. Notes\nthe migration and security wording lives in prose only\n'
  for i in 1 2 3 4; do printf '| T-00%s | AC-001 | src/main/java/A%s.java | t |\n' "$i" "$i"; done; } >"$D2/plan.md"
check "M3/AC12: 4 T-rows, 'migration' only in prose, profile feature → set-plan needs no plan-review" 'dcs "$P2" sE set-plan "$R2/plan.md" 2>/dev/null && [ "$(tj "$P2" "$id2" | jq -r .plan_approved)" = true ]'
P3="$(newplane dl3)"; id3="$(dcs "$P3" sF start --route full --profile feature --slug q 2>/dev/null | head -1)"; R3=".claude/claudehut/tasks/$id3"
printf '# Plan\n| T-001 | AC-001 | src/main/resources/db/migration/V2__x.sql | t |\n' >"$P3/$R3/plan.md"
check "M3: a sensitive path in a T-row's Files cell needs a plan-review APPROVE" '! dcs "$P3" sF set-plan "$R3/plan.md" 2>/dev/null'
P4="$(newplane dl4)"; id4="$(dcs "$P4" sG start --route full --profile migration --slug m 2>/dev/null | head -1)"; R4=".claude/claudehut/tasks/$id4"
printf '# Plan\n| T-001 | AC-001 | src/main/java/A.java | t |\n' >"$P4/$R4/plan.md"
check "M3: profile=migration needs a plan-review APPROVE" '! dcs "$P4" sG set-plan "$R4/plan.md" 2>/dev/null'

# light route: set-plan takes task.md (kind task); the full route does not
P5="$(newplane dl5)"; id5="$(dcs "$P5" sH start --route light --profile bugfix --slug l 2>/dev/null | head -1)"; R5=".claude/claudehut/tasks/$id5"
printf '# Task: x\n## 1. Approach\na\n## 2. Tasks\n| T-001 | AC-001 | src/main/java/A.java | t |\n' >"$P5/$R5/task.md"; : >"$STUB_LOG"
check "M3: light route set-plan task.md records plan_path + plan_approved, linted as kind task" \
  'dcs "$P5" sH set-plan "$R5/task.md" 2>/dev/null && [ "$(tj "$P5" "$id5" | jq -c "[.plan_path,.plan_approved]")" = "[\"$R5/task.md\",true]" ] && grep -q -- "--kind task" "$STUB_LOG"'
cp "$P5/$R5/task.md" "$D2/task.md"
check "M3: full route set-plan task.md is refused (the full route records plan.md)" '! dcs "$P2" sE set-plan "$R2/task.md" 2>/dev/null'

# set-plan checks the plan against the RECORDED spec (--spec spec_path); set-spec notes a plan pinned to an older
# spec-rev (06 §7 SpecRevN → PlanStale: exit 0, no state flag)
P6="$(newplane dl6)"; id6="$(dcs "$P6" sI start --route full --profile feature --slug r 2>/dev/null | head -1)"; R6=".claude/claudehut/tasks/$id6"
printf '# Spec: r\n> id: %s · profile: feature · route: full · rev: 1\n## 1. Context\nx\n' "$id6" >"$P6/$R6/spec.md"
printf '# Plan: r\n> id: %s · spec-rev: 1 · route: full · rev: 1\n| T-001 | AC-001 | src/main/java/A.java | t |\n' "$id6" >"$P6/$R6/plan.md"
dcs "$P6" sI set-spec "$R6/spec.md" >/dev/null 2>&1; : >"$STUB_LOG"
check "M3-V3: set-plan passes the recorded spec to the engine (--spec <spec_path>)" \
  'dcs "$P6" sI set-plan "$R6/plan.md" 2>/dev/null && grep -q -- "--spec $P6/$R6/spec.md" "$STUB_LOG"'
e="$(dcs "$P6" sI set-spec "$R6/spec.md" 2>&1)"
check "M3-V1: set-spec with the plan on the same spec-rev prints no stale-plan note" '! grep -q "pins spec-rev" <<<"$e"'
sed -i.bak 's/ rev: 1$/ rev: 2/' "$P6/$R6/spec.md"; before="$(tj "$P6" "$id6" | jq -c 'del(.spec_path, .updated)')"   # .updated is stamped per call (seconds)
e="$(dcs "$P6" sI set-spec "$R6/spec.md" 2>&1)"; r=$?
check "M3-V1: set-spec rev 2 over a plan pinned to spec-rev 1 → exit 0 + a re-plan note, no state flag" \
  '[ "$r" = 0 ] && grep -q "pins spec-rev 1, spec is now rev 2" <<<"$e" && [ "$(tj "$P6" "$id6" | jq -c "del(.spec_path, .updated)")" = "$before" ] && [ "$(tj "$P6" "$id6" | jq -r .plan_approved)" = true ]'

# the real engine against a minimal ch:schema template (DOCLINT_TEMPLATES), so it runs before the shipped templates do
if [ -f "$ROOT/scripts/doclint.sh" ] && command -v python3 >/dev/null 2>&1; then
  mkdir -p "$TMP/tpl"; printf '%s\n' '<!-- ch:schema kind=spec total=200' '1. Context | budget=100' '-->' '```markdown' '# Spec: <title>' '## 1. Context' '```' >"$TMP/tpl/spec-template.md"
  P7="$(newplane dl7)"; id7="$(cs "$P7" sJ start --route full --profile feature --slug j 2>/dev/null | head -1)"; R7=".claude/claudehut/tasks/$id7"
  printf '# Spec: x\n## 1. Context\nwhy\n```java\nclass A {}\n```\n' >"$P7/$R7/spec.md"
  e="$(DOCLINT_TEMPLATES="$TMP/tpl" cs "$P7" sJ set-spec "$R7/spec.md" 2>&1)"; r=$?
  check "M3 (real doclint): a spec with a java fence is refused by set-spec on L5, nothing recorded" \
    '[ "$r" = 1 ] && grep -q "^L5 blocking" <<<"$e" && [ -z "$(tj "$P7" "$id7" | jq -r ".spec_path // empty")" ]'
  printf '# Spec: x\n## 1. Context\nwhy now\n' >"$P7/$R7/spec.md"
  check "M3 (real doclint): a clean spec records" 'DOCLINT_TEMPLATES="$TMP/tpl" cs "$P7" sJ set-spec "$R7/spec.md" 2>/dev/null && [ "$(tj "$P7" "$id7" | jq -r .spec_path)" = "$R7/spec.md" ]'
fi

echo "STATE-TESTS: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
