#!/usr/bin/env bash
# verify-tests.sh — regression tests for the 0.12.7 kernel gates (docs/v0.20 06 §3, 04 §2; ADR K-05, K-13):
#   C*  claudehut-verify claims: a cited path must exist and its line must be in range; URLs, deleted-at-base files
#       and ambiguous basenames are not judged
#   F*  findings: task.outstanding and open table rows are reported
#   G*  gate engine through claudehut-state: mode warn records + proceeds, block refuses with task.json byte-identical,
#       --override proceeds and records the reason; end done needs review; the review binding goes stale on edit,
#       not on commit; spec/plan revision after review is caught; python3 missing → gate skipped with a notice
# Self-contained temp git repos, no network. Prints "VERIFY-TESTS: N passed, M failed"; exit 1 on failure.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CS="$ROOT/bin/claudehut-state"
CV="$ROOT/bin/claudehut-verify"
command -v jq >/dev/null 2>&1 || { echo "VERIFY-TESTS: jq missing"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "VERIFY-TESTS: python3 missing"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/verify tests.XXXXXX")"   # a space in the path on purpose (EVL-3)
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "ok - $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL - $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
unset CLAUDEHUT_GATE_MODE FORCE_COLOR

newrepo() { # $1 name → a git repo with a plane and one committed Java file of 5 lines
  local p="$TMP/$1"
  mkdir -p "$p/src/main/java/a" "$p/.claude/claudehut/tasks"
  printf 'l1\nl2\nl3\nl4\nl5\n' >"$p/src/main/java/a/Foo.java"
  printf 'x\n' >"$p/src/main/java/a/Gone.java"
  git -C "$p" init -q && git -C "$p" -c user.email=t@t -c user.name=t add -A && git -C "$p" -c user.email=t@t -c user.name=t commit -qm init
  printf '%s' "$p"
}
cs() { local p="$1" s="$2"; shift 2; CLAUDE_PROJECT_DIR="$p" "$CS" --session "$s" "$@"; }
tj() { cat "$1/.claude/claudehut/tasks/$2/task.json"; }
ev() { cat "$1/.claude/claudehut/tasks/$2/events.jsonl" 2>/dev/null; }
review() { # $1 abs path, $2 extra row (optional)
  mkdir -p "$(dirname "$1")"
  { printf '# Review\n| Item | Verdict | Locus |\n|------|---------|-------|\n| AC-001 | ✓ satisfied | src/main/java/a/Foo.java:3 |\n'
    [ -n "${2:-}" ] && printf '%s\n' "$2"
    printf '\n./gradlew test — 12 passed\n'; } >"$1"
}

# ── C: claims ──────────────────────────────────────────────────────────────────────────────────────────────
P="$(newrepo claims)"
md="$TMP/claims.md"
cat >"$md" <<'EOF'
| a | ✓ | src/main/java/a/Foo.java:3 |
| b | ✓ | Foo.java:4-5 |
| c | ✓ | src/main/java/a/Foo.java:9 |
| d | ✓ | src/main/java/a/Missing.java:1 |
see https://example.com/x/Bar.java:12 and io.f8a.Foo
EOF
out="$(CLAUDE_PROJECT_DIR="$P" "$CV" claims "$md" --json)"; rc=$?
check "C1: claims exits 1 when a cited path is wrong (rc=$rc)" '[ "$rc" = 1 ]'
check "C2: an existing path:line passes; basename resolves (2 problems total)" '[ "$(jq ".problems|length" <<<"$out")" = 2 ]'
check "C3: line past EOF is line-out-of-range" 'jq -e ".problems[]|select(.kind==\"line-out-of-range\" and .line==9)" <<<"$out" >/dev/null'
check "C4: an absent file is missing" 'jq -e ".problems[]|select(.kind==\"missing\" and (.path|endswith(\"Missing.java\")))" <<<"$out" >/dev/null'
check "C5: URLs are not claims" '! jq -e ".problems[]|select(.path|test(\"Bar.java\"))" <<<"$out" >/dev/null'
git -C "$P" rm -q src/main/java/a/Gone.java
id="$(cs "$P" s0 start --route light --slug c 2>/dev/null | head -1)"
printf '| e | ✓ | src/main/java/a/Gone.java:1 |\n' >"$TMP/gone.md"
git -C "$P" -c user.email=t@t -c user.name=t commit -qm rm 2>/dev/null
# base was taken at start (after git rm, before commit) → HEAD still has Gone.java at base
out="$(CLAUDE_PROJECT_DIR="$P" "$CV" claims "$TMP/gone.md" --task "$P/.claude/claudehut/tasks/$id" --json)"
check "C6: a file deleted by the task (present at base) is not a problem" '[ "$(jq ".problems|length" <<<"$out")" = 0 ]'

# ── F: findings ────────────────────────────────────────────────────────────────────────────────────────────
TD="$P/.claude/claudehut/tasks/$id"
jq '.outstanding=["fix X"]' "$TD/task.json" >"$TD/t" && mv "$TD/t" "$TD/task.json"
printf '| Sev | Where | Status |\n|---|---|---|\n| MED | Foo.java:2 | open |\n| LOW | Foo.java:1 | deferred |\n' >"$TMP/f.md"
out="$("$CV" findings --task "$TD" --evidence "$TMP/f.md" --json)"
check "F1: outstanding reported" 'jq -e ".problems[]|select(.kind==\"outstanding\")" <<<"$out" >/dev/null'
check "F2: an open row is reported, a deferred row is not" '[ "$(jq "[.problems[]|select(.kind==\"open-finding\")]|length" <<<"$out")" = 1 ]'

# ── G: gates through claudehut-state ───────────────────────────────────────────────────────────────────────
P="$(newrepo gw)"
id="$(cs "$P" s1 start --route light --slug w 2>/dev/null | head -1)"
cs "$P" s1 end --status done 2>"$TMP/err" ; rc=$?
check "G1: warn mode (default): end done with review pending proceeds (rc=$rc)" '[ "$rc" = 0 ] && [ "$(tj "$P" "$id" | jq -r .status)" = done ]'
check "G2: warn mode records gate.warned with the invariant" 'ev "$P" "$id" | jq -se "map(select(.type==\"gate.warned\" and .data.violations[0].invariant==\"end.done-requires-review\"))|length==1" >/dev/null'
check "G3: the warning is shown to the model" 'grep -q "review-not-done" "$TMP/err"'

P="$(newrepo gb)"
id="$(cs "$P" s2 start --route light --slug b 2>/dev/null | head -1)"
before="$(tj "$P" "$id")"
CLAUDEHUT_GATE_MODE=block cs "$P" s2 end --status done 2>/dev/null; rc=$?
check "G4: block mode refuses end done without review (rc=$rc)" '[ "$rc" = 1 ]'
check "G5: refused transition leaves task.json byte-identical" '[ "$(tj "$P" "$id")" = "$before" ]'
check "G6: refusal recorded as gate.blocked" 'ev "$P" "$id" | jq -se "map(select(.type==\"gate.blocked\"))|length==1" >/dev/null'
CLAUDEHUT_GATE_MODE=block cs "$P" s2 end --status done --override "hotfix, reviewed in PR 12" 2>/dev/null; rc=$?
check "G7: --override proceeds (rc=$rc)" '[ "$rc" = 0 ] && [ "$(tj "$P" "$id" | jq -r .status)" = done ]'
check "G8: override reason recorded" 'ev "$P" "$id" | jq -se "map(select(.type==\"gate.overridden\" and .data.reason==\"hotfix, reviewed in PR 12\"))|length==1" >/dev/null'
P2="$(newrepo gm)"; printf '{"gates":{"mode":"block"}}' >"$P2/.claude/claudehut/topology.json"
id2="$(cs "$P2" s3 start --route light --slug m 2>/dev/null | head -1)"
cs "$P2" s3 end --status done 2>/dev/null; rc=$?
check "G9: topology.json gates.mode=block is honoured (rc=$rc)" '[ "$rc" = 1 ]'
cs "$P2" s3 end --status abandoned 2>/dev/null; rc=$?
check "G10: end abandoned is never gated" '[ "$rc" = 0 ] && [ "$(tj "$P2" "$id2" | jq -r .status)" = abandoned ]'

# review-pass gate: a wrong citation
P="$(newrepo rp)"
id="$(cs "$P" s4 start --route light --slug r 2>/dev/null | head -1)"
R="$P/.claude/claudehut/tasks/$id/review.md"
review "$R" "| AC-002 | ✓ satisfied | src/main/java/a/Nope.java:7 |"
before="$(tj "$P" "$id")"
CLAUDEHUT_GATE_MODE=block cs "$P" s4 set-review pass --evidence ".claude/claudehut/tasks/$id/review.md" 2>"$TMP/err"; rc=$?
check "G11: block mode refuses set-review pass citing a missing file (rc=$rc)" '[ "$rc" = 1 ] && [ "$(tj "$P" "$id")" = "$before" ]'
check "G12: the refusal names the bad citation" 'grep -q "Nope.java" "$TMP/err"'
cs "$P" s4 set-review pass --evidence ".claude/claudehut/tasks/$id/review.md" 2>/dev/null; rc=$?
check "G13: warn mode passes the review and records gate.warned" '[ "$rc" = 0 ] && [ "$(tj "$P" "$id" | jq -r .review)" = pass ] && ev "$P" "$id" | jq -se "map(select(.type==\"gate.warned\" and .data.gate==\"review-pass\"))|length==1" >/dev/null'

# binding: commit does not stale the verdict, an edit does
P="$(newrepo bind)"
id="$(cs "$P" s5 start --route light --slug k 2>/dev/null | head -1)"
printf 'l1\nl2\nCHANGED\nl4\nl5\n' >"$P/src/main/java/a/Foo.java"
R="$P/.claude/claudehut/tasks/$id/review.md"; review "$R"
cs "$P" s5 set-review pass --evidence ".claude/claudehut/tasks/$id/review.md" 2>/dev/null
check "G14: set-review pass stores a review_binding with a fingerprint" '[ -n "$(tj "$P" "$id" | jq -r ".review_binding.fingerprint[\".\"] // empty")" ]'
git -C "$P" -c user.email=t@t -c user.name=t commit -qam change
out="$(CLAUDE_PROJECT_DIR="$P" "$CV" verdict --task "$P/.claude/claudehut/tasks/$id" --json)"
check "G15: committing the reviewed change keeps the verdict current" '[ "$(jq ".problems|length" <<<"$out")" = 0 ]'
printf 'l1\nl2\nCHANGED AGAIN\nl4\nl5\n' >"$P/src/main/java/a/Foo.java"
before="$(tj "$P" "$id")"
CLAUDEHUT_GATE_MODE=block cs "$P" s5 end --status done 2>"$TMP/err"; rc=$?
check "G16: an edit after review makes end done stale in block mode (rc=$rc)" '[ "$rc" = 1 ] && grep -q "tree-changed" "$TMP/err" && [ "$(tj "$P" "$id")" = "$before" ]'

P="$(newrepo plan)"
id="$(cs "$P" s6 start --route light --slug p 2>/dev/null | head -1)"
TDIR="$P/.claude/claudehut/tasks/$id"
printf '# Task\n## Approach\nx\n' >"$TDIR/task.md"
jq --arg p ".claude/claudehut/tasks/$id/task.md" '.plan_path=$p' "$TDIR/task.json" >"$TDIR/t" && mv "$TDIR/t" "$TDIR/task.json"
review "$TDIR/review.md"
cs "$P" s6 set-review pass --evidence ".claude/claudehut/tasks/$id/review.md" 2>/dev/null
printf '# Task\n## Approach\ny (revised)\n' >"$TDIR/task.md"
out="$(CLAUDE_PROJECT_DIR="$P" "$CV" verdict --task "$TDIR" --json)"
check "G17: a plan revised after review is caught (plan-changed)" 'jq -e ".problems[]|select(.kind==\"plan-changed\")" <<<"$out" >/dev/null'

P="$(newrepo nopy)"
id="$(cs "$P" s7 start --route light --slug n 2>/dev/null | head -1)"
CLAUDEHUT_PYTHON=/nonexistent/python3 CLAUDEHUT_GATE_MODE=block cs "$P" s7 end --status done 2>"$TMP/err"; rc=$?
check "G18: python3 missing → gate skipped with a notice, transition proceeds (rc=$rc)" '[ "$rc" = 0 ] && grep -q "skipped: kernel unavailable" "$TMP/err"'

# ── H: host probe (ENV-1) ──────────────────────────────────────────────────────────────────────────────────
CK="$ROOT/bin/claudehut-kernel"
H="$TMP/home"; mkdir -p "$H/.claude"
cat >"$TMP/rw.sh" <<'EOF'
#!/usr/bin/env bash
c="$(jq -r .tool_input.command)"
case "$c" in git*) jq -nc --arg c "wrap $c" '{hookSpecificOutput:{hookEventName:"PreToolUse",updatedInput:{command:$c}}}' ;; esac
EOF
chmod +x "$TMP/rw.sh"
P="$(newrepo probe)"
jq -nc --arg c "'$TMP/rw.sh'" '{hooks:{PreToolUse:[{matcher:"Bash",hooks:[{type:"command",command:$c}]}]}}' >"$H/.claude/settings.json"
out="$(HOME="$H" CLAUDE_PLUGIN_DATA="$TMP/pd" "$CK" probe --project "$P")"
check "H1: a Bash hook that rewrites git is detected empirically" '[ "$(jq -r ".bash_hooks[0].rewrites[\"git status\"]" <<<"$out")" = "wrap git status" ]'
HOME="$H" CLAUDE_PLUGIN_DATA="$TMP/pd" "$CK" probe --project "$P" --write >/dev/null
adv="$(HOME="$H" CLAUDE_PLUGIN_DATA="$TMP/pd" "$CK" probe --project "$P" --advice --cached)"
check "H2: --cached advice (SessionStart path, runs nothing) names the absolute-path workaround" 'grep -q "/usr/bin/git" <<<"$adv"'
check "H3: --write stores state/env-profile.json" '[ "$(jq -r .rewriters "$P/.claude/claudehut/state/env-profile.json")" = 1 ]'
jq -nc '{hooks:{PreToolUse:[{matcher:"Bash",hooks:[{type:"command",command:"true"}]},{matcher:"Bash",hooks:[{type:"command",command:"${CLAUDE_PLUGIN_ROOT}/scripts/x.sh"}]}]}}' >"$H/.claude/settings.json"
out="$(HOME="$H" CLAUDE_PLUGIN_DATA="$TMP/pd2" "$CK" probe --project "$P")"
adv="$(HOME="$H" CLAUDE_PLUGIN_DATA="$TMP/pd2" "$CK" probe --project "$P" --advice)"
check "H4: a non-rewriting hook gives no advice; ClaudeHut's own hook is excluded" '[ -z "$adv" ] && [ "$(jq ".bash_hooks|length" <<<"$out")" = 1 ]'
out="$(HOME="$H" CLAUDE_PLUGIN_DATA="$TMP/pd3" CLAUDEHUT_PROBE_HOOKS=0 "$CK" probe --project "$P")"
check "H5: CLAUDEHUT_PROBE_HOOKS=0 lists hooks untested, runs nothing" '[ "$(jq -r ".bash_hooks[0].tested" <<<"$out")" = false ]'
out="$(HOME="$H" CLAUDE_PLUGIN_DATA="$TMP/pd" ANTHROPIC_API_KEY=x "$CK" probe --project "$P")"
check "H6: auth_mode api when ANTHROPIC_API_KEY is set (K-17)" '[ "$(jq -r .auth_mode <<<"$out")" = api ]'
out="$(HOME="$H" CLAUDE_PLUGIN_DATA="$TMP/pd" env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN "$CK" probe --project "$P")"
check "H7: auth_mode plan by default" '[ "$(jq -r .auth_mode <<<"$out")" = plan ]'

# ── L: learning truth maintenance (KNW-2) ──────────────────────────────────────────────────────────────────
P="$(newrepo learn)"
LS="$P/.claude/claudehut/learnings.jsonl"
printf '%s\n' '{"id":"L-0001","category":"pitfall","trigger":"a|b","learning":"lesson one is long enough","evidence":"A.java:1","confidence":0.9,"hits":3}' \
  '{"id":"L-0002","category":"pitfall","trigger":"c|d","learning":"lesson two is long enough","evidence":"B.java:1","confidence":0.9,"hits":3}' >"$LS"
CLAUDE_PROJECT_DIR="$P" "$CK" learn retract L-0001 --reason "wrong: Spring binds lists wholesale" >/dev/null; rc=$?
check "L1: retract marks status, reason and time (rc=$rc)" '[ "$rc" = 0 ] && [ "$(jq -sr ".[0].status" "$LS")" = retracted ] && [ -n "$(jq -sr ".[0].retracted_at" "$LS")" ]'
check "L2: other rows untouched, no lock left" '[ "$(jq -sr ".[1].status // \"none\"" "$LS")" = none ] && [ ! -e "$LS.lock" ]'
CLAUDE_PROJECT_DIR="$P" "$CK" learn retract L-0001 >/dev/null 2>&1; rc=$?
check "L3: retract without --reason is a usage error" '[ "$rc" = 2 ]'
CLAUDE_PROJECT_DIR="$P" "$CK" learn retract L-0099 --reason x >/dev/null 2>&1; rc=$?
check "L4: unknown id exits 1" '[ "$rc" = 1 ]'
O="$(CLAUDE_PROJECT_DIR="$P" bash "$ROOT/scripts/inject-learnings.sh" --top 10 2>/dev/null)"
check "L5: the injector skips a retracted learning" '! grep -q "lesson one" <<<"$O" && grep -q "lesson two" <<<"$O"'
HB="$TMP/hubdir"; mkdir -p "$HB"
printf '%s\n' '{"id":"F-0054","category":"pitfall","trigger":"x","learning":"fleet lesson","scope":"fleet"}' >"$HB/fleet-learnings.jsonl"
CLAUDE_PROJECT_DIR="$P" "$CK" learn verify F-0054 --by "BindingTest#envListReplacesWhole" --hub "$HB" >/dev/null
check "L6: verify on a hub store records verified_by" '[ "$(jq -r .verified_by "$HB/fleet-learnings.jsonl")" = "BindingTest#envListReplacesWhole" ]'

# ── R: review-fix regressions ──────────────────────────────────────────────────────────────────────────────
P="$(newrepo fix)"
id="$(cs "$P" s9 start --route light --slug f 2>/dev/null | head -1)"
printf 'class New {}\n' >"$P/src/main/java/a/New.java"
R="$P/.claude/claudehut/tasks/$id/review.md"; review "$R"
cs "$P" s9 set-review pass --evidence ".claude/claudehut/tasks/$id/review.md" 2>/dev/null
git -C "$P" add -A src; out1="$(CLAUDE_PROJECT_DIR="$P" "$CV" verdict --task "$P/.claude/claudehut/tasks/$id" --json)"
git -C "$P" -c user.email=t@t -c user.name=t commit -qm new; out2="$(CLAUDE_PROJECT_DIR="$P" "$CV" verdict --task "$P/.claude/claudehut/tasks/$id" --json)"
check "R1: a NEW file staged then committed after review is not tree-changed" '[ "$(jq ".problems|length" <<<"$out1")" = 0 ] && [ "$(jq ".problems|length" <<<"$out2")" = 0 ]'
mkdir -p "$P/.claude/rules"; printf 'x\n' >"$P/.claude/rules/r.md"
out3="$(CLAUDE_PROJECT_DIR="$P" "$CV" verdict --task "$P/.claude/claudehut/tasks/$id" --json)"
check "R2: Learn writing .claude/rules after review does not stale the verdict" '[ "$(jq ".problems|length" <<<"$out3")" = 0 ]'
cat >"$TMP/dom.md" <<'EOF'
| Payment state | Meaning |
|---|---|
| PENDING | awaiting capture |
| OPEN | breaker rejects calls |

| Sev | Where | Status |
|---|---|---|
| LOW | Foo.java:1 | deferred |

```
at org.springframework.web.servlet.DispatcherServlet.doDispatch(DispatcherServlet.java:1067)
```
Add application-prod.yml later. Config in ~/.claude/settings.json and .github/ci.yml.
EOF
mkdir -p "$P/.github"; printf 'on: push\n' >"$P/.github/ci.yml"
out="$("$CV" findings --task "$P/.claude/claudehut/tasks/$id" --evidence "$TMP/dom.md" --json)"
check "R3: domain tables (PENDING/OPEN states) are not open findings; only a Status column counts" '[ "$(jq ".problems|length" <<<"$out")" = 0 ]'
out="$(CLAUDE_PROJECT_DIR="$P" "$CV" claims "$TMP/dom.md" --json)"
check "R4: fenced traces, proposed files, ~/ paths are not judged; .github/ resolves (got $(jq -c "[.problems[].path]" <<<"$out"))" '[ "$(jq ".problems|length" <<<"$out")" = 0 ]'
P="$(newrepo ovr)"
id="$(cs "$P" s10 start --route light --slug o 2>/dev/null | head -1)"
CLAUDEHUT_GATE_MODE=block cs "$P" s10 end --status done --override "-x" 2>/dev/null; rc=$?
check "R5: an override that looks like a flag is still a reason (no argparse bypass)" '[ "$rc" = 0 ] && ev "$P" "$id" | jq -se "map(select(.type==\"gate.overridden\" and .data.reason==\"-x\"))|length==1" >/dev/null'
P="$(newrepo crash)"
id="$(cs "$P" s11 start --route light --slug c 2>/dev/null | head -1)"
TD="$P/.claude/claudehut/tasks/$id"; jq '.review="pass" | .review_binding="corrupt"' "$TD/task.json" >"$TD/t" && mv "$TD/t" "$TD/task.json"
printf '#!/usr/bin/env bash\nexit 1\n' >"$TMP/k1"; chmod +x "$TMP/k1"
CLAUDEHUT_GATE_MODE=block cs "$P" s11 end --status done 2>"$TMP/err"; rc=$?
check "R6: a malformed binding is not a refusal" '[ "$rc" = 0 ]'
P="$(newrepo crash2)"
id="$(cs "$P" s12 start --route light --slug c 2>/dev/null | head -1)"
CLAUDEHUT_PYTHON="$TMP/k1" CLAUDEHUT_GATE_MODE=block cs "$P" s12 end --status done 2>"$TMP/err"; rc=$?
check "R7: a kernel that exits 1 WITHOUT a block decision does not refuse; gate.skipped is noted" '[ "$rc" = 0 ] && grep -q "skipped" "$TMP/err"'

# ── B: budget overrun is an event, never a refusal (PLN-3) ───────────────────────────────────────────────────
P="$(newrepo budget)"
id="$(cs "$P" s8 start --route light --slug bu 2>/dev/null | head -1)"
printf '#!/usr/bin/env bash\necho "budget: total 2400/1500 · §1 Approach 90/80"\nexit 0\n' >"$TMP/doclint-stub.sh"
printf '# Task\n## Approach\nx\n## Tasks\n| T | Goal |\n|---|---|\n| T1 | g |\n' >"$P/.claude/claudehut/tasks/$id/task.md"
CLAUDEHUT_DOCLINT="$TMP/doclint-stub.sh" cs "$P" s8 set-plan ".claude/claudehut/tasks/$id/task.md" 2>"$TMP/err"; rc=$?
check "B1: an over-budget plan is still recorded (rc=$rc)" '[ "$rc" = 0 ] && [ "$(tj "$P" "$id" | jq -r .plan_approved)" = true ]'
check "B2: the overrun is a budget.exceeded event with words and budget" 'ev "$P" "$id" | jq -se "map(select(.type==\"budget.exceeded\" and .data.words==2400 and .data.budget==1500))|length==1" >/dev/null'
check "B3: the model is told the overrun in percent" 'grep -q "+60%" "$TMP/err"'

# ── S: selftest canaries (VER-3) ───────────────────────────────────────────────────────────────────────────
out="$("$CK" selftest --json)"; rc=$?
check "S1: selftest on this tree: every control alive (rc=$rc, dead=$(jq .dead <<<"$out"))" '[ "$rc" = 0 ] && [ "$(jq .dead <<<"$out")" = 0 ]'
check "S2: selftest covers every hooks.json command plus 4 canaries" '[ "$(jq .controls <<<"$out")" -ge 17 ]'
CP="$TMP/plugin copy"; mkdir -p "$CP"
( cd "$ROOT" && tar --exclude=.git --exclude=evals --exclude=.claude -cf - . ) | ( cd "$CP" && tar -xf - )
printf '#!/usr/bin/env bash\necho "{}"; echo "{}"\n' >"$CP/scripts/hint-explore.sh"
printf '#!/usr/bin/env bash\nexit 0\n' >"$CP/scripts/record-failure.sh"
out="$("$CP/bin/claudehut-kernel" selftest --json)"; rc=$?
check "S3: a hook printing two JSON objects is reported DEAD (rc=$rc)" '[ "$rc" = 1 ] && jq -e ".results[]|select(.control|test(\"hint-explore\"))|select(.ok==false)" <<<"$out" >/dev/null'
check "S4: a silent no-op failure recorder is reported DEAD" 'jq -e ".results[]|select(.control|test(\"record-failure keeps\"))|select(.ok==false)" <<<"$out" >/dev/null'

echo "VERIFY-TESTS: $PASS passed, $FAIL failed"
[ -n "${EVAL_COUNT_DIR:-}" ] && printf '%s\n' "$PASS" >"$EVAL_COUNT_DIR/verify-tests.count" 2>/dev/null
[ "$FAIL" = 0 ]
