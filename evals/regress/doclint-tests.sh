#!/usr/bin/env bash
# doclint-tests.sh — regression tests for scripts/doclint.sh (v0.12 M3, 06 §6 rules L1–L11 + CLI contract).
# Every rule has a violating case that asserts its `L<n> <blocking|advisory>` token (so deleting the rule fails
# the suite) and the clean fixtures in evals/fixtures/doclint/good assert no violation at all.
# Templates: evals/fixtures/doclint/templates (06 §5 shapes) via DOCLINT_TEMPLATES; set DOCLINT_TESTS_REAL=1 to
# also lint the good fixtures against the real skills/*/references templates.
# Self-contained temp dirs, no network, < 10 s. Prints "DOCLINT-TESTS: N passed, M failed"; exit 1 on failure.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DL="$ROOT/scripts/doclint.sh"
FX="$ROOT/evals/fixtures/doclint"
export DOCLINT_TEMPLATES="$FX/templates"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/doclint-tests.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/    /' | head -8; }

N=0
# case <kind-file> [python replace pairs as OLD NEW ...] → prints the new case dir (a copy of good/ + mutation)
case_dir() {
  N=$((N+1)); local d="$TMP/tasks/$(printf '%04d' "$N")-case"; mkdir -p "$d"; cp "$FX"/good/*.md "$d/"; printf '%s' "$d"
}
mut() { # mut FILE OLD NEW [OLD NEW ...] — literal replace, fails loudly when OLD is absent
  python3 - "$@" <<'PY'
import sys
p = sys.argv[1]; s = open(p, encoding='utf-8').read(); a = sys.argv[2:]
for i in range(0, len(a), 2):
    if a[i] not in s: sys.exit('mut: %r not in %s' % (a[i], p))
    s = s.replace(a[i], a[i + 1].replace('\\n', '\n'), 1)
open(p, 'w', encoding='utf-8').write(s)
PY
}
append() { printf '%b' "$2" >>"$1"; }
run() { OUT="$(bash "$DL" --language en "$@" 2>&1)"; RC=$?; }

# expect LABEL TOKEN(regex) RC FILE [args]  — output must match TOKEN and exit code must equal RC
expect() {
  local label="$1" tok="$2" want="$3"; shift 3
  run "$@"
  if grep -Eq -- "$tok" <<<"$OUT" && [ "$RC" = "$want" ]; then ok "$label"; else bad "$label (rc=$RC want $want; want /$tok/)" "$OUT"; fi
}
# absent LABEL TOKEN(regex) FILE [args] — output must NOT match TOKEN
absent() {
  local label="$1" tok="$2"; shift 2
  run "$@"
  if ! grep -Eq -- "$tok" <<<"$OUT"; then ok "$label"; else bad "$label (unexpected /$tok/)" "$OUT"; fi
}

# ---------------------------------------------------------------- clean fixtures
for k in spec plan plan-review task brainstorm; do
  run "$FX/good/$k.md"
  if [ "$RC" = 0 ] && ! grep -Eq '^L[0-9]+ ' <<<"$OUT"; then ok "good $k.md is clean"; else bad "good $k.md is clean" "$OUT"; fi
done

# ---------------------------------------------------------------- L1 header vs task.json
d="$(case_dir)"
expect "L1 profile mismatch (--profile)" '^L1 blocking header: profile: feature but expected bugfix \(from --profile\)' 1 "$d/spec.md" --profile bugfix
printf '{"schema":2,"id":"0001","route":"light","profile":"feature"}' >"$d/task.json"
expect "L1 route mismatch (--state)" '^L1 blocking header: route: full but expected light \(from task\.json\)' 1 "$d/spec.md" --state "$d/task.json"
absent "L1 skipped without --state/--profile" '^L1 ' "$d/spec.md"
d="$(case_dir)"; mut "$d/spec.md" ' · profile: feature' ''
expect "L1 a header key the template declares is missing (gate: --profile)" '^L1 blocking header: no profile:' 1 "$d/spec.md" --profile feature
absent "L1 missing key not checked standalone" '^L1 ' "$d/spec.md"

# ---------------------------------------------------------------- L2 headings
d="$(case_dir)"; append "$d/brainstorm.md" '\n# AMENDMENT after adversarial critique\nmore\n'
expect "L2 AMENDMENT heading (any level)" '^L2 blocking heading: forbidden heading "AMENDMENT' 1 "$d/brainstorm.md"
d="$(case_dir)"; append "$d/spec.md" '\n## Round 2 changes\nx\n'
expect "L2 Round N heading" '^L2 blocking .*forbidden heading "Round 2 changes"' 1 "$d/spec.md"
d="$(case_dir)"; mut "$d/spec.md" '## 6. Decisions' '## Decision Record (MADR-lite)'
expect "L2 heading outside allowlist lists the allowlist" '^L2 blocking Decision Record \(MADR-lite\): heading .* not in allowlist: 1\. Context, .*6\. Decisions' 1 "$d/spec.md"
expect "L2 missing required heading" '^L2 blocking §6 Decisions: missing required heading "## 6. Decisions"' 1 "$d/spec.md"
d="$(case_dir)"; mut "$d/spec.md" '## 5. Contracts' '## 5. Placeholder' '## 1. Context' '## 5. Contracts' '## 5. Placeholder' '## 1. Context'
expect "L2 out of order" '^L2 blocking .*out of order' 1 "$d/spec.md"
d="$(case_dir)"; mut "$d/spec.md" 'profile: feature' 'profile: bugfix' '## 4. Flow' '## 7. Scratch' '## 5. Contracts' '## 7. Scratch2'
python3 - "$d/spec.md" <<'PY'
import sys,re; p=sys.argv[1]; s=open(p).read()
s=re.sub(r'## 7\. Scratch\n.*?(?=## 6\. Decisions)', '', s, flags=re.S); open(p,'w').write(s)
PY
absent "L2 bugfix spec does not need Flow/Contracts" '^L2 ' "$d/spec.md"
d="$(case_dir)"; mut "$d/spec.md" 'rev: 1' 'rev: 2'
expect "L2 rev>1 needs a Changelog" '^L2 blocking Changelog: rev: 2 needs' 1 "$d/spec.md"
append "$d/spec.md" '\n## Changelog\n- rev 2 — cap wording — owner\n'
absent "L2 rev>1 with Changelog passes" '^L2 ' "$d/spec.md"
d="$(case_dir)"; mut "$d/plan.md" '| ID | Goal | Files | Test first |' '| ID | Files | Goal | Test first |'
expect "L2 plan Tasks table columns (Files must be column 3)" '^L2 blocking §4 Tasks: table columns' 1 "$d/plan.md"

# ---------------------------------------------------------------- L3 section budget
d="$(case_dir)"; mut "$d/spec.md" 'Partial refunds' "$(printf 'word%.0s ' $(seq 1 130))Partial refunds"
expect "L3 section over budget is advisory (exit 0)" '^L3 advisory §1 Context: section 1[0-9]{2}/120 \(budget\)' 0 "$d/spec.md"

# ---------------------------------------------------------------- L4 total (+ report, language factor)
d="$(case_dir)"
python3 - "$d/task.md" <<'PY'
import sys; p=sys.argv[1]; s=open(p).read()
n = 900 - 43
s = s.replace('## 2. Tasks', '\n'.join(['filler words here now'] * (n // 4)) + (' x' * (n % 4)) + '\n\n## 2. Tasks'); open(p,'w').write(s)
PY
expect "L4 total over budget is advisory" '^L4 advisory total: total 900/600' 0 "$d/task.md"
expect "L4 --report prints 900/600, exit 0 (AC-11)" '\| total \| 900/600 \|' 0 --report "$d/task.md"
OUT="$(bash "$DL" --language vi --mode report "$d/task.md" 2>&1)"; RC=$?
if grep -q '900/840 (600×1,4)' <<<"$OUT" && [ "$RC" = 0 ]; then ok "L4 language=vi prints 900/840 (600×1,4) (AC-16)"; else bad "L4 vi factor" "$OUT"; fi
mkdir -p "$TMP/plane/.claude/claudehut/tasks/0001-x"; cp "$d/task.md" "$TMP/plane/.claude/claudehut/tasks/0001-x/"
printf '{"schema":1,"mode":"mono","language":"vi"}' >"$TMP/plane/.claude/claudehut/topology.json"
OUT="$(bash "$DL" "$TMP/plane/.claude/claudehut/tasks/0001-x/task.md" 2>&1)"
if grep -q 'total 900/840 (600×1,4)' <<<"$OUT"; then ok "language read from the plane's topology.json"; else bad "topology.json language" "$OUT"; fi
printf '{"schema":1,"mode":"microservice","hub":"../../../hub"}' >"$TMP/plane/.claude/claudehut/topology.json"
mkdir -p "$TMP/hub"; printf '{"language":"vi"}' >"$TMP/hub/hub.json"
OUT="$(bash "$DL" "$TMP/plane/.claude/claudehut/tasks/0001-x/task.md" 2>&1)"
if grep -q '(600×1,4)' <<<"$OUT"; then ok "language inherited from hub.json"; else bad "hub.json language" "$OUT"; fi
rm -f "$TMP/plane/.claude/claudehut/topology.json"
OUT="$(bash "$DL" "$TMP/plane/.claude/claudehut/tasks/0001-x/task.md" 2>&1)"
if grep -q 'total 900/600' <<<"$OUT"; then ok "no topology.json → en"; else bad "default en" "$OUT"; fi

# ---------------------------------------------------------------- L5 fences
d="$(case_dir)"; append "$d/plan.md" '\n```java\nclass Foo {}\n```\n'
expect "L5 java fence is blocking" '^L5 blocking .*```java fence' 1 "$d/plan.md"
d="$(case_dir)"; append "$d/spec.md" '\n```kotlin\nval x = 1\n```\n'
expect "L5 kotlin fence is blocking" '^L5 blocking .*```kotlin fence' 1 "$d/spec.md"
d="$(case_dir)"; append "$d/spec.md" "\n\`\`\`json\n$(printf '"k": 1,\\n%.0s' $(seq 1 20))\`\`\`\n"
expect "L5 json fence of 20 lines is blocking" '^L5 blocking .*```json fence has 20 lines \(max 12\)' 1 "$d/spec.md"
d="$(case_dir)"; mut "$d/spec.md" 'sequenceDiagram' 'erDiagram'
expect "L5 mermaid must be flowchart/graph/sequence/state" '^L5 blocking §4 Flow: mermaid must start' 1 "$d/spec.md"
d="$(case_dir)"; append "$d/spec.md" '\n```yaml\na: 1\n'
expect "L5 unclosed fence" '^L5 blocking .*unclosed' 1 "$d/spec.md"

# ---------------------------------------------------------------- L6 cell caps
d="$(case_dir)"
python3 - "$d/spec.md" <<'PY'
import sys; p=sys.argv[1]; s=open(p).read()
old='In the refund use case, facing overshoot, we derive the ceiling as a SUM'
s=s.replace(old, ' '.join(['word'] * 120)); open(p,'w').write(s)
PY
expect "L6 Decision cell 120w/80w (AC-2 text), exit 0" '^L6 advisory §6 Decisions: cell Decision — 120w/80w \(budget\)' 0 "$d/spec.md"
expect "L6 same number in --report" 'cell Decision — 120w/80w' 0 --mode report "$d/spec.md"
d="$(case_dir)"; mut "$d/plan.md" 'RefundCeilingTest#over' "$(printf 'x%.0s' $(seq 1 70))"
expect "L6 Test first cell over 60 chars" '^L6 advisory §4 Tasks: cell Test first — 70c/60c' 0 "$d/plan.md"
d="$(case_dir)"; mut "$d/plan.md" '## 4. Tasks' '## 4. Task Breakdown' 'RefundCeilingTest#over' "$(printf 'x%.0s' $(seq 1 70))"
expect "L6 applies by column name outside its section (legacy plans)" '^L6 advisory .*cell Test first — 70c/60c' 1 "$d/plan.md"

# ---------------------------------------------------------------- L7 diagram=required
d="$(case_dir)"
python3 - "$d/spec.md" <<'PY'
import sys,re; p=sys.argv[1]; s=open(p).read()
s=re.sub(r'```mermaid.*?```\n', 'The client posts a refund.\n', s, flags=re.S); open(p,'w').write(s)
PY
expect "L7 feature Flow without mermaid or n/a" '^L7 blocking §4 Flow: needs a ```mermaid diagram' 1 "$d/spec.md"
mut "$d/spec.md" 'The client posts a refund.' 'n/a — single synchronous call only'
absent "L7 'n/a — <reason>' satisfies the diagram" '^L7 ' "$d/spec.md"
mut "$d/spec.md" 'n/a — single synchronous call only' 'n/a — trivial'
expect "L7 n/a reason needs >=3 words" '^L7 blocking' 1 "$d/spec.md"

# ---------------------------------------------------------------- L8 [NEEDS CLARIFICATION]
d="$(case_dir)"; mut "$d/spec.md" 'Partial refunds' '[NEEDS CLARIFICATION: which amount?] Partial refunds'
expect "L8 open marker outside Open Questions blocks" '^L8 blocking §1 Context: open \[NEEDS CLARIFICATION\]' 1 "$d/spec.md"
d="$(case_dir)"; append "$d/spec.md" '- [NEEDS CLARIFICATION: a] non-blocking\n- [NEEDS CLARIFICATION: b] non-blocking\n- [NEEDS CLARIFICATION: c] non-blocking\n'
expect "L8 more than 3 markers" '^L8 blocking header: 4 \[NEEDS CLARIFICATION\] markers \(max 3\)' 1 "$d/spec.md"
d="$(case_dir)"; mut "$d/spec.md" '] non-blocking, owner: PO' '], owner: PO'
expect "L8 untagged marker in Open Questions blocks" '^L8 blocking §7 Open Questions' 1 "$d/spec.md"

# ---------------------------------------------------------------- L9 decisions
d="$(case_dir)"; mut "$d/spec.md" '| accepted |' '| proposed |'
expect "L9 Status outside the set" '^L9 blocking §6 Decisions: Status "proposed"' 1 "$d/spec.md"
d="$(case_dir)"; mut "$d/spec.md" '| accepted |' '| superseded-by D-9 |'
expect "L9 superseded-by an unknown decision" '^L9 blocking .*superseded-by D-9 — no such decision' 1 "$d/spec.md"
mut "$d/spec.md" 'superseded-by D-9 |' 'superseded-by D-2 |\n| D-2 | we keep a SUM per refund | counter | test | accepted |'
absent "L9 superseded-by an existing decision passes" '^L9 ' "$d/spec.md"
d="$(case_dir)"; mut "$d/spec.md" 'RefundCeilingTest | accepted |' 'RefundCeilingTest | accepted |\n| D-1 | dup | x | y | accepted |'
expect "L9 duplicate decision ID" '^L9 blocking .*duplicate decision ID D-1' 1 "$d/spec.md"

# ---------------------------------------------------------------- L10 plan ↔ spec
d="$(case_dir)"; mut "$d/plan.md" 'spec-rev: 1' 'spec-rev: 2'
expect "L10 spec-rev differs from the spec rev" '^L10 blocking header: spec-rev: 2 but spec is rev 1' 1 "$d/plan.md"
d="$(case_dir)"; mut "$d/plan.md" 'spec-rev: 1 · ' ''
expect "L10 plan without spec-rev" '^L10 blocking header: plan header has no spec-rev' 1 "$d/plan.md"
d="$(case_dir)"; mut "$d/plan.md" '| AC-002, D-1 |' '| D-1 |'
expect "L10 AC not covered by any Req cell" '^L10 blocking Req: AC-002 not covered' 1 "$d/plan.md"
d="$(case_dir)"; mut "$d/plan.md" '| AC-002, D-1 |' '| AC-002, AC-009 |'
expect "L10 Req id missing from the spec" '^L10 blocking §4 Tasks: Req AC-009 does not exist' 1 "$d/plan.md"
d="$(case_dir)"; cp "$d/spec.md" "$TMP/other-spec.md"; rm "$d/spec.md"; mut "$TMP/other-spec.md" 'rev: 1' 'rev: 3'
d="$(case_dir)"; rm "$d/spec.md"
expect "L10 no spec, standalone → advisory" '^L10 advisory header: coverage not checked' 0 "$d/plan.md"
expect "L10 no spec, gate on the full route → blocking" '^L10 blocking header: no spec to check coverage against' 1 "$d/plan.md" --route full
expect "L10 --spec path overrides the sibling" '^L10 blocking header: spec-rev: 1 but spec is rev 3' 1 "$d/plan.md" --spec "$TMP/other-spec.md"

# ---------------------------------------------------------------- L11 plan-review
d="$(case_dir)"; append "$d/plan-review.md" '\nVerdict: APPROVE\n'
expect "L11 two Verdict lines" '^L11 blocking header: want exactly one "Verdict:" line, found 2' 1 "$d/plan-review.md"
d="$(case_dir)"; mut "$d/plan-review.md" 'Verdict: REVISE' 'Verdict: MAYBE'
expect "L11 Verdict value" '^L11 blocking header: Verdict "MAYBE"' 1 "$d/plan-review.md"
d="$(case_dir)"
expect "L11 Verdict differs from the command (--verdict)" '^L11 blocking header: file says Verdict: REVISE but the command says APPROVE' 1 "$d/plan-review.md" --verdict APPROVE
absent "L11 matching --verdict passes" '^L11 ' "$d/plan-review.md" --verdict REVISE
d="$(case_dir)"; mut "$d/plan-review.md" '| HIGH |' '| LOW |'
expect "L11 Sev outside CRIT|HIGH|MED" '^L11 blocking Findings: Sev "LOW"' 1 "$d/plan-review.md"
d="$(case_dir)"; mut "$d/plan-review.md" '| ID | Sev | Locus | Gap | Fix |' '| ID | Severity | Where | Gap | Fix | Owner |'
expect "L11 Findings table columns" '^L11 blocking Findings: table columns' 1 "$d/plan-review.md"
d="$(case_dir)"; for i in $(seq 2 11); do append "$d/plan-review.md" "| F$i | MED | T1 | gap | fix |\n"; done
python3 - "$d/plan-review.md" <<'PY'
import sys; p=sys.argv[1]; s=open(p).read()
body, tail = s.split('\n## Notes\nNone.\n', 1)
open(p,'w').write(body.rstrip('\n') + '\n' + tail + '\n## Notes\nNone.\n')
PY
expect "L11 more than 10 findings is advisory" '^L11 advisory Findings: 11 findings rows' 0 "$d/plan-review.md"

# ---------------------------------------------------------------- CLI contract
d="$(case_dir)"; append "$d/plan.md" '\n```java\nclass Foo {}\n```\n'
OUT="$(bash "$DL" --json --language en "$d/plan.md")"; RC=$?
if [ "$RC" = 1 ] && python3 -c 'import json,sys; o=json.loads(sys.argv[1]); assert o["kind"]=="plan" and o["blocking"][0]["rule"]=="L5" and "budget" in o and "advisory" in o and o["file"]' "$OUT" 2>/dev/null
then ok "--json object {file,kind,blocking,advisory,budget}, exit 1 on blocking"; else bad "--json shape" "$OUT"; fi
OUT="$(bash "$DL" --advise "$d/plan.md")"; RC=$?
if [ "$RC" = 0 ] && [ "$(printf '%s\n' "$OUT" | grep -c .)" = 1 ] && grep -q '1 blocking' <<<"$OUT"; then ok "--advise: one line, exit 0 on blocking"; else bad "--advise one line" "$OUT"; fi
if grep -q '^L5 ' <<<"$OUT" && ! grep -q "$TMP" <<<"$OUT" && ! grep -q 'doclint\.sh' <<<"$OUT" && grep -q ' in plan\.md$' <<<"$OUT"
then ok "--advise: rule id first, no absolute path, no non-runnable command hint"; else bad "--advise line shape" "$OUT"; fi
OUT="$(bash "$DL" --advise "$FX/good/plan.md")"; RC=$?
if [ "$RC" = 0 ] && [ -z "$OUT" ]; then ok "--advise silent on a clean file"; else bad "--advise clean" "$OUT"; fi
mkdir -p "$TMP/src/main/java"; echo 'class Foo {}' >"$TMP/src/main/java/Foo.java"
OUT="$(bash "$DL" --advise "$TMP/src/main/java/Foo.java" 2>&1)"; RC=$?
if [ "$RC" = 0 ] && [ -z "$OUT" ]; then ok "--advise silent on a non-artifact (AC-10)"; else bad "--advise non-artifact" "$OUT"; fi
run "$TMP/src/main/java/Foo.java"
if [ "$RC" = 2 ]; then ok "unknown kind: exit 2 in default mode"; else bad "unknown kind rc=$RC" "$OUT"; fi
cp "$FX/good/spec.md" "$TMP/notes.md"
expect "--kind overrides filename inference" 'budget: total 135/1200' 0 --kind spec "$TMP/notes.md"
mkdir -p "$TMP/empty-tpl"
OUT="$(DOCLINT_TEMPLATES="$TMP/empty-tpl" bash "$DL" "$FX/good/spec.md" 2>&1)"; RC=$?
if [ "$RC" = 2 ] && grep -q 'no spec-template.md' <<<"$OUT"; then ok "missing template: gate errors (exit 2)"; else bad "missing template gate rc=$RC" "$OUT"; fi
OUT="$(DOCLINT_TEMPLATES="$TMP/empty-tpl" bash "$DL" --advise "$FX/good/spec.md" 2>&1)"; RC=$?
if [ "$RC" = 0 ] && [ -z "$OUT" ]; then ok "missing template: advise silent"; else bad "missing template advise" "$OUT"; fi
cat >"$TMP/context.md" <<'EOF'
# Context: x
## Index brief
n/a — index not built
## Explorer map
- src/main/Foo.java:12
EOF
expect "context.md with 'n/a — index not built' passes" 'budget:' 0 "$TMP/context.md"
OUT="$(bash "$DL" --self-test 2>&1)"; RC=$?
if [ "$RC" = 0 ] && grep -q 'DOCLINT SELF-TEST: PASS' <<<"$OUT"; then ok "--self-test passes"; else bad "--self-test" "$OUT"; fi
t0=$(python3 -c 'import time; print(time.time())')
bash "$DL" --language en "$FX/good/plan.md" >/dev/null
ms=$(python3 -c "import time; print(int((time.time()-$t0)*1000))")
if [ "$ms" -lt 500 ]; then ok "one file lints fast (${ms} ms)"; else bad "slow: ${ms} ms"; fi

if [ "${DOCLINT_TESTS_REAL:-0}" = 1 ]; then
  for k in spec plan plan-review task brainstorm; do
    OUT="$(DOCLINT_TEMPLATES= bash "$DL" --language en "$FX/good/$k.md" 2>&1)"; RC=$?
    if [ "$RC" = 0 ]; then ok "real template: good $k.md passes"; else bad "real template: good $k.md" "$OUT"; fi
  done
fi

echo "DOCLINT-TESTS: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
