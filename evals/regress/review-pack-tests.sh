#!/usr/bin/env bash
# review-pack-tests.sh — regression pins for scripts/review-pack.sh (08-review.md §3–§4, §7, AC 1–5, 7, 12).
# Deterministic, no Claude, no network. Fixture repos are built in a temp dir from the specs under
# evals/tasks/review-pack/ (cases/<name>/{case.json,base/,head/} and probes.tsv).
#
#   1. case fixtures        lanes / skipped / reasons / partial / depth / pack content per case.json
#   2. rule probes          one probe per signal rule; every rule of the table has a probe
#   3. rule removal         each rule line deleted from a copy of the script → its probe reason disappears
#                           (proves every rule is pinned; skip with REVIEW_PACK_NO_MUTANTS=1)
#   4. task mode            task.base + pre_dirty + enforcement routing (hints, never a lane) + packs under tasks/<id>/review/
#   5. snapshot             index/worktree untouched, `git diff <reviewed_tree>` empty (tracked; untracked via a
#                           throwaway index), 4000-line diff → large, ask_user, every pack ≤1500 lines; a path with a
#                           space; root-level src/ packages named docs/build/target/generated
#   6. round 2 / 3          carry ∪ fix-diff lanes (fix committed / uncommitted / untracked in src); round 3 capped
#   7. degraded             no jq → exit 0 + one JSON line; --only perf → db; missing task.json; HEAD~1 fallback
#
# Run: evals/regress/review-pack-tests.sh
#      REVIEW_PACK_SCRIPT=<copy of review-pack.sh> …   (point at a modified copy, e.g. to prove a pin fails)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RP="${REVIEW_PACK_SCRIPT:-$ROOT/scripts/review-pack.sh}"
FX="$ROOT/evals/tasks/review-pack"
export CLAUDE_PLUGIN_ROOT="$ROOT" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
unset CLAUDEHUT_SESSION_ID CLAUDE_PROJECT_DIR CLAUDEHUT_FEDERATION_ROOT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; }
chk() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
export TMPDIR="$W/tmp"; mkdir -p "$TMPDIR"

# rp <repo> [args…] → OUT (stdout), RC; the contract: exit 0 and exactly one JSON object line
rp() {
  local r="$1"; shift
  OUT="$(cd "$r" && bash "$RP" "$@" 2>"$W/stderr")"; RC=$?
  if [ "$RC" -ne 0 ] || [ "$(printf '%s\n' "$OUT" | grep -c .)" -ne 1 ] || ! jq -e 'type=="object"' <<<"$OUT" >/dev/null 2>&1; then
    bad "contract: rc=$RC stdout=$(printf '%s' "$OUT" | head -c 200)"
  fi
}
lanes()   { jq -r '[.lanes[].lane] | join(",")' <<<"$OUT"; }
skipped() { jq -r '[.skipped[].lane] | sort | join(",")' <<<"$OUT"; }
pack()    { jq -r --arg l "$1" '.lanes[] | select(.lane==$l) | .pack' <<<"$OUT"; }
has_reason() { jq -e --arg l "$1" --arg r "$2" '[.lanes[] | select(.lane==$l) | .reasons[]] | index($r) != null' <<<"$OUT" >/dev/null; }

git_init() { git init -q "$1" && git -C "$1" config commit.gpgsign false; }
commit_all() { git -C "$1" add -A && git -C "$1" commit -qm "$2" --no-verify; }

# build <case dir> <mode> → repo path in $REPO, base commit in $BASE
build() {
  local c="$1" mode="$2" d
  REPO="$W/repo-$(basename "$c")-$mode"; rm -rf "$REPO"; git_init "$REPO"
  [ -d "$c/base" ] && cp -R "$c/base/." "$REPO/"
  printf 'seed\n' > "$REPO/.seed"; commit_all "$REPO" base
  BASE="$(git -C "$REPO" rev-parse HEAD)"
  [ -d "$c/head" ] && cp -R "$c/head/." "$REPO/"
  for d in $(jq -r '.delete[]? // empty' "$c/case.json"); do rm -f "$REPO/$d"; done
  case "$mode" in commit) commit_all "$REPO" head ;; esac
}

echo "== 1. case fixtures"
for c in "$FX"/cases/*/; do
  c="${c%/}"; n="$(basename "$c")"; J="$c/case.json"
  build "$c" "$(jq -r '.mode // "commit"' "$J")"
  rp "$REPO" --base "$BASE" --route "$(jq -r '.route' "$J")"
  exp="$(jq -r '.lanes | join(",")' "$J")"
  chk "$n: lanes = $exp" '[ "$(lanes)" = "$exp" ]'
  exp="$(jq -r '.skipped | sort | join(",")' "$J")"
  chk "$n: skipped = $exp" '[ "$(skipped)" = "$exp" ]'
  if jq -e 'has("files")' "$J" >/dev/null; then
    exp="$(jq -r .files "$J")"; chk "$n: FILES has $exp entr(y|ies)" '[ "$(jq .files <<<"$OUT")" = "$exp" ]'
  fi
  if jq -e 'has("uncovered")' "$J" >/dev/null; then
    exp="$(jq -c .uncovered "$J")"; chk "$n: uncovered = $exp" '[ "$(jq -c .uncovered <<<"$OUT")" = "$exp" ]'
  fi
  if jq -e 'has("partial")' "$J" >/dev/null; then   # lanes.json partial:[{lane,uncovered}] (08 §3.2 option (a))
    exp="$(jq -c '.partial' "$J")"
    chk "$n: partial = $exp" '[ "$(jq -c "[.partial[]? | {(.lane): .uncovered}] | add // {}" <<<"$OUT")" = "$exp" ]'
  fi
  while IFS="$(printf '\t')" read -r l r; do
    [ -n "$l" ] && chk "$n: $l reason '$r'" 'has_reason "$l" "$r"'
  done < <(jq -r '.reasons // {} | to_entries[] | .key as $k | .value[] | [$k, .] | @tsv' "$J")
  while IFS="$(printf '\t')" read -r l d; do
    [ -n "$l" ] && chk "$n: $l depth $d" '[ "$(jq -r --arg l "$l" ".lanes[]|select(.lane==\$l)|.depth" <<<"$OUT")" = "$d" ]'
  done < <(jq -r '.depth // {} | to_entries[] | [.key, .value] | @tsv' "$J")
  while IFS="$(printf '\t')" read -r l s; do
    [ -n "$l" ] && chk "$n: $l pack contains '$s'" 'grep -qF -- "$s" "$(pack "$l")"'
  done < <(jq -r '.pack_contains // {} | to_entries[] | .key as $k | .value[] | [$k, .] | @tsv' "$J")
  while IFS="$(printf '\t')" read -r l s; do
    [ -n "$l" ] && chk "$n: $l pack lacks '$s'" '! grep -qF -- "$s" "$(pack "$l")"'
  done < <(jq -r '.pack_lacks // {} | to_entries[] | .key as $k | .value[] | [$k, .] | @tsv' "$J")
done

echo "== 2. rule probes"
PROBES="$W/probes"; grep -v '^#' "$FX/probes.tsv" > "$PROBES"
PR="$W/repo-probes"; git_init "$PR"; printf 'seed\n' > "$PR/.seed"; commit_all "$PR" base; PBASE="$(git -C "$PR" rev-parse HEAD)"
mkdir -p "$PR/.claude/claudehut/tasks/0001-probe"
ENFSET='[]'
while IFS="$(printf '\t')" read -r kind label path line; do
  case "$kind" in
    enf) ENFSET="$(jq -c --arg i "$path" '. + [$i]' <<<"$ENFSET")" ;;
    *) mkdir -p "$PR/$(dirname "$path")"; printf '%s\n' "$line" > "$PR/$path" ;;
  esac
done < "$PROBES"
commit_all "$PR" probes
jq -nc --arg b "$PBASE" --argjson e "$ENFSET" '{schema:2,id:"0001-probe",route:"full",base:{".":$b},pre_dirty:{".":[]},enforcement_set:$e}' \
  > "$PR/.claude/claudehut/tasks/0001-probe/task.json"
expected_reason() { # kind label path → the reason string the probe must produce
  case "$1" in path) printf 'path:%s %s' "$2" "$3" ;; enf) printf 'enf:%s' "$3" ;; *) printf 'hunk:%s %s' "$2" "${3##*/}" ;; esac
}
probe_lane() { awk "/^cat <<'RULES'/{f=1;next} /^RULES/{f=0} f" "$RP" | awk -v k="$1" -v l="$2" '$2==k && $3==l {print $1; exit}'; }
run_probes() { # $1 script → PROBE_OUT
  PROBE_OUT="$(cd "$PR" && CLAUDE_PROJECT_DIR="$PR" bash "$1" --task 0001-probe --out "$W/probe-out" 2>/dev/null)"
}
run_probes "$RP"
while IFS="$(printf '\t')" read -r kind label path line; do
  lane="$(probe_lane "$kind" "$label")"; r="$(expected_reason "$kind" "$label" "$path")"
  chk "probe $kind '$label' → $lane reason '$r'" \
    '[ -n "$lane" ] && jq -e --arg l "$lane" --arg r "$r" "[(.lanes[]|select(.lane==\$l)|.reasons[]), (.hints[]?|select(.lane==\$l)|.reason)]|index(\$r)!=null" <<<"$PROBE_OUT" >/dev/null'
done < "$PROBES"
RULE_LINES="$W/rule-lines"; awk "/^cat <<'RULES'/{f=1;next} /^RULES/{f=0} f" "$RP" > "$RULE_LINES"
missing="$(while read -r lane kind label re; do awk -F'\t' -v k="$kind" -v l="$label" '$1==k && $2==l {f=1} END{exit !f}' "$PROBES" || echo "$kind:$label"; done < "$RULE_LINES")"
chk "every rule of the signal table has a probe ($(wc -l < "$RULE_LINES" | tr -d ' ') rules)" '[ -z "$missing" ]'
[ -z "$missing" ] || echo "    missing: $missing"
# kafka-config path rule (PO 0004 CON-9, CRITICAL missed; decided 2026-10-01): each spelling selects contract,
# src/test and a non-kafka *Config do not
K="$W/repo-kafka-config"; git_init "$K"; printf 'seed\n' > "$K/.seed"; commit_all "$K" base; KB="$(git -C "$K" rev-parse HEAD)"
for p in src/main/java/x/kafka/TopicsConfig.java svc/src/main/java/x/PaymentProducerConfig.java src/main/java/x/KafkaConfig.java \
         src/test/java/x/KafkaConfigTest.java src/main/java/x/config/AppConfig.java; do
  mkdir -p "$K/$(dirname "$p")"; printf 'class %s {}\n' "$(basename "$p" .java)" > "$K/$p"; done
commit_all "$K" head
rp "$K" --base "$KB" --route light
for p in src/main/java/x/kafka/TopicsConfig.java svc/src/main/java/x/PaymentProducerConfig.java src/main/java/x/KafkaConfig.java; do
  chk "kafka-config: $p → contract" 'has_reason contract "path:kafka-config $p"'; done
chk "kafka-config: src/test KafkaConfigTest and config/AppConfig select nothing" '[ "$(jq "[.lanes[].reasons[]|select(startswith(\"path:kafka-config\"))]|length" <<<"$OUT")" = 3 ]'

echo "== 3. rule removal (each rule line deleted → its probe fails)"
if [ "${REVIEW_PACK_NO_MUTANTS:-0}" = 1 ]; then echo "  skip - REVIEW_PACK_NO_MUTANTS=1"; else
  start="$(grep -n "^cat <<'RULES'" "$RP" | cut -d: -f1)"; i=0
  mkdir -p "$W/mut"; : > "$W/mut/jobs"
  while read -r lane kind label re; do
    i=$((i+1)); sed "$((start + i))d" "$RP" > "$W/mut/m$i.sh"
    p="$(awk -F'\t' -v k="$kind" -v l="$label" '$1==k && $2==l {print; exit}' "$PROBES")"
    printf '%s\t%s\t%s\n' "$i" "$kind:$label" "$(expected_reason "$kind" "$label" "$(printf '%s' "$p" | cut -f3)")" >> "$W/mut/jobs"
  done < "$RULE_LINES"
  # mutants run 8 at a time: one run each on the probe repo, the deleted rule's probe reason must be gone
  export PR W
  tr '\n' '\0' < "$W/mut/jobs" | xargs -0 -P 8 -n 1 bash -c '
    IFS="$(printf "\t")" read -r i name r <<<"$1"
    out="$(cd "$PR" && CLAUDE_PROJECT_DIR="$PR" bash "$W/mut/m$i.sh" --task 0001-probe --out "$W/mut/out$i" 2>/dev/null)"
    if jq -e --arg r "$r" "[.lanes[].reasons[], .hints[]?.reason]|index(\$r)!=null" <<<"$out" >/dev/null 2>&1 || [ -z "$out" ]; then echo "$name" > "$W/mut/survived$i"; fi' _
  survived="$(cat "$W"/mut/survived* 2>/dev/null | tr '\n' ' ')"
  chk "all $i rule deletions are caught by their probe" '[ -z "$survived" ]'
  [ -z "$survived" ] || echo "    survived:$survived"
fi

echo "== 4. task mode (task.base, pre_dirty, enforcement routing, pack dir)"
T="$W/repo-task"; git_init "$T"; T="$(cd "$T" && pwd -P)"; mkdir -p "$T/src/main/java/com/x/service"
printf 'class OrderService {}\n' > "$T/src/main/java/com/x/service/OrderService.java"
printf 'class Dirty {}\n' > "$T/src/main/java/com/x/service/Dirty.java"
commit_all "$T" base
TB="$(git -C "$T" rev-parse --short HEAD)"
printf 'class Dirty { int wip; }\n' > "$T/src/main/java/com/x/service/Dirty.java"   # dirty before the task started
mkdir -p "$T/.claude/claudehut/tasks/0003-t" "$T/.claude/claudehut/state"
jq -nc --arg b "$TB" '{schema:2,id:"0003-t",route:"full",base:{".":$b},pre_dirty:{".":["src/main/java/com/x/service/Dirty.java"]},
  enforcement_set:["security/authn.md","framework/r2dbc.md","coding/naming.md"]}' > "$T/.claude/claudehut/tasks/0003-t/task.json"
printf '{"schema":2,"active_task":"0003-t"}\n' > "$T/.claude/claudehut/state/sid-1.json"
printf 'class OrderService { @Transactional void n() {} }\n' > "$T/src/main/java/com/x/service/OrderService.java"   # the task's change (uncommitted)
rp "$T" --session sid-1
chk "base from task.base[.] (short sha resolved)" '[ "$(jq -r .base_source <<<"$OUT")" = "task.base[.]" ] && [ "$(jq -r .base_sha <<<"$OUT")" = "$(git -C "$T" rev-parse "$TB")" ]'
chk "route read from task.json (full → test-runner); enforcement selects no lane (security only hinted)" '[ "$(jq -r .route <<<"$OUT")" = full ] && [ "$(lanes)" = "reviewer,test,db" ]'
chk "pre_dirty file excluded, plane .claude/ excluded (FILES=1)" '[ "$(jq .files <<<"$OUT")" = 1 ] && ! grep -q Dirty.java "$(pack reviewer)"'
chk "packs + lanes.json under tasks/<id>/review/" '[ "$(jq -r .out_dir <<<"$OUT")" = "$T/.claude/claudehut/tasks/0003-t/review" ] && [ -f "$T/.claude/claudehut/tasks/0003-t/review/lanes.r1.json" ] && [ -f "$T/.claude/claudehut/tasks/0003-t/review/lanes.json" ] && [ -f "$T/.claude/claudehut/tasks/0003-t/review/r1.db.md" ]'
chk "the pack dir ignores itself (packs quote hunks verbatim, maybe a secret line)" '[ "$(cat "$T/.claude/claudehut/tasks/0003-t/review/.gitignore")" = "*" ] && git -C "$T" check-ignore -q .claude/claudehut/tasks/0003-t/review/r1.db.md'
chk "enforcement prefix only hints security (hints + skipped reason), its item goes to the reviewer with escalate" 'jq -e "[.hints[]|select(.lane==\"security\")|.reason]==[\"enf:security/authn.md\"] and ([.skipped[]|select(.lane==\"security\")|.reason][0]|test(\"enforcement hint: 1\"))" <<<"$OUT" >/dev/null && grep -q "^- security/authn.md (lane security not run: escalate: security" "$(pack reviewer)"'
chk "a hunk-selected lane carrying an enforcement item → depth deep; reasons hold no enf:" '[ "$(jq -r ".lanes[]|select(.lane==\"db\")|.depth" <<<"$OUT")" = deep ] && ! jq -e "[.lanes[].reasons[]]|any(startswith(\"enf:\"))" <<<"$OUT" >/dev/null'
chk "framework/r2dbc routes to db (pack only, not the reviewer)" 'grep -q "^- framework/r2dbc.md" "$(pack db)" && ! grep -q "framework/r2dbc.md" "$(pack reviewer)"'
chk "an item no prefix claims goes to the reviewer pack only" 'grep -q "^- coding/naming.md" "$(pack reviewer)" && ! grep -q "coding/naming.md" "$(pack db)"'
chk "pack header pins base_sha, reviewed_tree, round, route, lane" '( for k in base_sha head_sha reviewed_tree round route lane reasons files; do grep -q "^$k:" "$(pack db)" || exit 1; done )'
chk "--task with no task.json → degraded, exit 0" 'rp "$T" --task 9999-none; jq -e ".degraded==true" <<<"$OUT" >/dev/null'

echo "== 5. snapshot purity + large diff"
L="$W/repo-large"; git_init "$L"; mkdir -p "$L/src/main/java/l"
for i in $(seq 1 45); do printf 'class L%s {}\n' "$i" > "$L/src/main/java/l/L$i.java"; done
commit_all "$L" base; LB="$(git -C "$L" rev-parse HEAD)"
for i in $(seq 1 44); do { printf 'class L%s {\n' "$i"; seq 1 90 | sed 's/^/  int f/; s/$/;/'; echo '  @Query("x") void q();'; echo "}"; } > "$L/src/main/java/l/L$i.java"; done
git -C "$L" add src/main/java/l/L1.java                                        # something staged in the REAL index
printf 'class Untracked {}\n' > "$L/src/main/java/l/Untracked.java"            # untracked, enters the snapshot
cp "$L/.git/index" "$W/index.before"; git -C "$L" status --porcelain > "$W/status.before"
rp "$L" --base "$LB" --route full
TREE="$(jq -r .head_tree <<<"$OUT")"
chk "real index byte-identical after the snapshot" 'cmp -s "$L/.git/index" "$W/index.before"'
chk "git status unchanged after the snapshot" 'git -C "$L" status --porcelain | cmp -s - "$W/status.before"'
# AC5: tracked paths show no difference; the untracked file shows as D only because the real index lacks it —
# in a throwaway copy of the index with intent-to-add it compares equal too
chk "git diff <reviewed_tree> is empty for tracked paths (AC5)" '[ "$(git -C "$L" diff --name-status "$TREE" -- src)" = "$(printf "D\tsrc/main/java/l/Untracked.java")" ]'
cp "$L/.git/index" "$W/index.throwaway"
chk "untracked FILES equal the tree (throwaway index + add -N → git diff <reviewed_tree> empty)" 'GIT_INDEX_FILE="$W/index.throwaway" git -C "$L" add -N -- src/main/java/l/Untracked.java && [ -z "$(GIT_INDEX_FILE="$W/index.throwaway" git -C "$L" diff --stat "$TREE")" ] && cmp -s "$L/.git/index" "$W/index.before"'
chk "the untracked src file is in the reviewed tree" 'git -C "$L" cat-file -e "$TREE:src/main/java/l/Untracked.java"'
chk "diff >1500 lines → large + ask_user with a reason" '[ "$(jq -c "[.large,.ask_user]" <<<"$OUT")" = "[true,true]" ] && jq -e ".diff_lines>1500 and (.ask_reason|test(\"--paths\"))" <<<"$OUT" >/dev/null'
chk "every pack ≤1500 lines (reported and on disk)" 'jq -e "all(.lanes[]; .lines<=1500)" <<<"$OUT" >/dev/null && ( for p in $(jq -r ".lanes[].pack" <<<"$OUT"); do [ "$(wc -l < "$p")" -le 1500 ] || exit 1; done )'
chk "overflow files are listed by name with the pinned git diff command" 'grep -q "not inlined: run git diff $LB $TREE -- " "$(pack reviewer)"'
chk ">30 files alone → large" 'rp "$L" --base "$LB" --route light --paths src/main/java/l; jq -e ".files>30 and .large" <<<"$OUT" >/dev/null'
chk "--paths narrows FILES" 'rp "$L" --base "$LB" --route light --paths src/main/java/l/L2.java; [ "$(jq .files <<<"$OUT")" = 1 ]'

# a path with a space: git ends the ---/+++ header with a TAB; the pack must still inline every file
S="$W/repo-space"; git_init "$S"; mkdir -p "$S/src/main/java/com/x"
printf 'class OrderService {}\n' > "$S/src/main/java/com/x/OrderService.java"; commit_all "$S" base; SB="$(git -C "$S" rev-parse HEAD)"
printf 'class OrderService { int changed; }\n' > "$S/src/main/java/com/x/OrderService.java"
printf 'class NewSvc { @Transactional void x() {} }\n' > "$S/src/main/java/com/x/New Svc.java"
rp "$S" --base "$SB" --route light
chk "spaced path: no awk error, both files inlined, the spaced file signals db" '! grep -q "awk" "$W/stderr" && [ "$(jq .files <<<"$OUT")" = 2 ] && grep -qF "int changed" "$(pack reviewer)" && grep -qF "class NewSvc" "$(pack reviewer)" && has_reason db "hunk:@Transactional New Svc.java"'
# root-level src/: a package named docs is source (08 §4 excludes only root docs/**); dropped paths are reported
X="$W/repo-excl"; git_init "$X"; printf 'seed\n' > "$X/.seed"; commit_all "$X" base; XB="$(git -C "$X" rev-parse HEAD)"
for pk in docs build target generated; do mkdir -p "$X/src/main/java/com/x/$pk"; printf 'class A { @Transactional void x() {} }\n' > "$X/src/main/java/com/x/$pk/A.java"; done
mkdir -p "$X/docs"; printf 'x\n' > "$X/docs/n.md"; commit_all "$X" head
rp "$X" --base "$XB" --route full
chk "root src/**/docs/ kept (db via hunk); build/target/generated + root docs/ listed in excluded" '[ "$(jq .files <<<"$OUT")" = 1 ] && has_reason db "hunk:@Transactional A.java" && [ "$(jq -c "[.excluded_count, (.excluded|index(\"docs/n.md\")!=null)]" <<<"$OUT")" = "[4,true]" ]'

echo "== 6. round 2 / round 3 (ADR-V8, AC4)"
R2C="$FX/round2"
for mode in commit worktree untracked; do
  R="$W/repo-r2-$mode"; git_init "$R"; cp -R "$R2C/base/." "$R/"; commit_all "$R" base; RB="$(git -C "$R" rev-parse HEAD)"
  cp -R "$R2C/head/." "$R/"; commit_all "$R" r1
  rp "$R" --base "$RB" --route full --out "$W/r2out-$mode"
  T1="$(jq -r .head_tree <<<"$OUT")"
  [ "$mode" = commit ] && chk "round 1: lanes = reviewer,test,security,contract" '[ "$(lanes)" = "reviewer,test,security,contract" ]'
  case "$mode" in
    commit)    cp -R "$R2C/fix/." "$R/"; commit_all "$R" fix ;;
    worktree)  cp -R "$R2C/fix/." "$R/" ;;
    untracked) cp -R "$R2C/fix-untracked/." "$R/" ;;
  esac
  rp "$R" --round 2 --prev "$R2C/review-r1.md" --base "$T1" --route full --out "$W/r2out-$mode"
  chk "round 2 ($mode fix): lanes = reviewer,test,security (carry ∪ fix-diff), FILES = the fix only" '[ "$(lanes)" = "reviewer,test,security" ] && [ "$(jq .files <<<"$OUT")" = 1 ]'
  chk "round 2 ($mode fix): a carried lane with no signal packs every file → partial = []" '[ "$(jq -c .partial <<<"$OUT")" = "[]" ]'
  chk "round 2 ($mode fix): security carried, contract (✓ in r1) not re-run" 'has_reason security "carry: still ✗ in round 1" && jq -e "[.skipped[].lane]|index(\"contract\")!=null" <<<"$OUT" >/dev/null'
  chk "round 2 ($mode fix): pack header says round 2, lanes.r1.json kept" 'grep -q "^round: 2" "$(pack security)" && [ -f "$W/r2out-$mode/lanes.r1.json" ] && [ -f "$W/r2out-$mode/lanes.r2.json" ]'
  [ "$mode" = commit ] && { rp "$R" --round 2 --prev "$R2C/review-r1-skill.md" --base "$T1" --route full --out "$W/r2skill"
    chk "round 2 (--prev in the skills/review §4 Lanes shape, OUTSTANDING (n)): lanes = reviewer,test,security" '[ "$(lanes)" = "reviewer,test,security" ] && has_reason security "carry: still ✗ in round 1"'; }
done
# task mode: the task's enforcement set (security/db/contract prefixes) must not re-select lanes in round 2
RT="$W/repo-r2-task"; git_init "$RT"; RT="$(cd "$RT" && pwd -P)"; cp -R "$R2C/base/." "$RT/"; commit_all "$RT" base
RTB="$(git -C "$RT" rev-parse HEAD)"; cp -R "$R2C/head/." "$RT/"; commit_all "$RT" r1
mkdir -p "$RT/.claude/claudehut/tasks/0005-r2"
jq -nc --arg b "$RTB" '{schema:2,id:"0005-r2",route:"full",base:{".":$b},pre_dirty:{".":[]},
  enforcement_set:["security/spring-security.md","framework/r2dbc.md","observability/metrics.md"]}' > "$RT/.claude/claudehut/tasks/0005-r2/task.json"
rp "$RT" --task 0005-r2
chk "round 1 (task): framework/r2dbc hints db but does not select it" 'jq -e "[.hints[]|select(.lane==\"db\")|.reason]|index(\"enf:framework/r2dbc.md\")!=null" <<<"$OUT" >/dev/null && ! [[ ",$(lanes)," == *,db,* ]]'
cp -R "$R2C/fix/." "$RT/"
rp "$RT" --task 0005-r2 --round 2 --carry-lanes security
chk "round 2 (task, enforcement set, fix in a service): lanes = reviewer,test,security" '[ "$(lanes)" = "reviewer,test,security" ] && [ "$(jq -r .base_source <<<"$OUT")" = "round 1 head_tree" ]'
chk "round 2 (task): the carried security pack still lists its enforcement item" 'grep -q "^- security/spring-security.md" "$(pack security)"'
rp "$R" --round 2 --carry-lanes security --route full --out "$W/r2out-untracked"
chk "round 2 without --base: base = round-1 head_tree from lanes.r1.json" '[ "$(jq -r .base_source <<<"$OUT")" = "round 1 head_tree" ] && [ "$(jq -r .base_sha <<<"$OUT")" = "$T1" ]'
chk "--carry-lanes alias perf → db" 'rp "$R" --round 2 --carry-lanes perf --base "$T1" --route full --out "$W/r2x"; has_reason db "carry: still ✗ in round 1"'
D2="$W/repo-r2-docs"; git_init "$D2"; cp -R "$R2C/base/." "$D2/"; commit_all "$D2" base; DB2="$(git -C "$D2" rev-parse HEAD)"
mkdir -p "$D2/docs"; printf 'x\n' > "$D2/docs/n.md"; printf 'x\n' > "$D2/NOTES.md"
rp "$D2" --round 2 --carry-lanes security --base "$DB2" --route full --out "$W/r2d"
chk "round 2: a fix touching no source does not re-run test-runner" '[ "$(lanes)" = "reviewer,security" ]'
# untracked implement output stays untracked across rounds: in round 2 it equals BASE (the round-1 tree) and must
# not re-select the lanes it triggered in round 1
U="$W/repo-r2-untr"; git_init "$U"; mkdir -p "$U/src/main/java/com/x"
printf 'class OrderService {}\n' > "$U/src/main/java/com/x/OrderService.java"; printf 'readme\n' > "$U/README.md"; commit_all "$U" base
UB="$(git -C "$U" rev-parse HEAD)"
printf 'interface FooRepository {}\n' > "$U/src/main/java/com/x/FooRepository.java"
printf 'class JwtFilter {}\n' > "$U/src/main/java/com/x/JwtFilter.java"
printf 'class OrderService { int a; }\n' > "$U/src/main/java/com/x/OrderService.java"
rp "$U" --base "$UB" --route full --out "$W/r2u"
chk "round 1 (untracked Repository + Filter): lanes = reviewer,test,security,db" '[ "$(lanes)" = "reviewer,test,security,db" ]'
U1="$(jq -r .head_tree <<<"$OUT")"
printf 'class OrderService { int a, b; }\n' > "$U/src/main/java/com/x/OrderService.java"
rp "$U" --round 2 --base "$U1" --route full --out "$W/r2u"
chk "round 2, service-only fix, untracked files unchanged: lanes = reviewer,test, FILES = 1" '[ "$(lanes)" = "reviewer,test" ] && [ "$(jq .files <<<"$OUT")" = 1 ]'
U2="$(jq -r .head_tree <<<"$OUT")"; printf 'readme 2\n' > "$U/README.md"
rp "$U" --round 2 --base "$U2" --route full --out "$W/r2u2"
chk "round 2, README-only fix: lanes = reviewer (no test-runner)" '[ "$(lanes)" = "reviewer" ] && [ "$(jq .files <<<"$OUT")" = 1 ]'
rp "$R" --round 3 --out "$W/r3"
chk "round 3 → capped, no lanes" '[ "$(jq -c "[.capped,(.lanes|length)]" <<<"$OUT")" = "[true,0]" ]'

echo "== 7. degraded paths"
SH="$W/nojq"; mkdir -p "$SH"
for t in bash git sed tr cat mktemp dirname grep; do p="$(command -v "$t")" && ln -sf "$p" "$SH/$t"; done
OUT="$(cd "$L" && env PATH="$SH" bash "$RP" --only perf 2>/dev/null)"; RC=$?
chk "no jq → exit 0, one JSON line, degraded:true (AC7)" '[ "$RC" = 0 ] && [ "$(printf "%s\n" "$OUT" | grep -c .)" = 1 ] && jq -e ".degraded==true" <<<"$OUT" >/dev/null'
chk "no jq + --only perf → lanes reviewer,db" '[ "$(lanes)" = "reviewer,db" ]'
rp "$L" --base "$LB" --route light --only perf
chk "--only perf with jq → reviewer,db" '[ "$(lanes)" = "reviewer,db" ]'
rp "$L" --base "$LB" --route light --only security
chk "--only narrows: a signalled lane not named is skipped as --only" '[ "$(lanes)" = "reviewer,security" ] && [ "$(jq -r ".skipped[]|select(.lane==\"db\")|.reason" <<<"$OUT")" = "--only security" ]'
H="$W/repo-h1"; git_init "$H"; printf 'a\n' > "$H/a.txt"; commit_all "$H" one; printf 'b\n' > "$H/b.txt"; commit_all "$H" two
rp "$H"
chk "no upstream/origin: base = HEAD~1; no task → light, temp pack dir" '[ "$(jq -r .base_source <<<"$OUT")" = "HEAD~1" ] && [ "$(jq -r .route <<<"$OUT")" = light ] && [ -d "$(jq -r .out_dir <<<"$OUT")" ]'
chk "outside a git repo → degraded, exit 0" 'mkdir -p "$W/nogit"; rp "$W/nogit"; jq -e ".degraded==true" <<<"$OUT" >/dev/null'

echo
echo "review-pack-tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
