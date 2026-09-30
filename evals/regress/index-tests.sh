#!/usr/bin/env bash
# index-tests.sh — regression pins for bin/claudehut-index + scripts/index/{claudehut_index,extract}.py
# (07-index-memory.md §4.2, §5–§7, AC-4/5/7/13; ADR-IDX-1/2/5/8). Deterministic, no Claude, no network.
# The fixture repo is built in a temp dir from evals/fixtures/index/spring-mini (+ probes.tsv).
#
#   1. extraction       every rule probe holds; every file passes test -f and its line points at the source;
#                       negatives (comment, DTO, src/test, nested record); deterministic bytes; no __pycache__
#   2. rule removal     each `# rule:` line deleted from a copy of extract.py → its probe fails (INDEX_NO_MUTANTS=1 skips)
#   3. read-only        status/brief/find/svc/links leave every mtime of the repo (incl. .git) unchanged, fresh and
#                       stale (CLAUDEHUT_INDEX_NO_SPAWN=1); brief ≤ budget, stale banner, vi banner, --task terms
#   4. freshness        2 commits × 3 java files → behind 2, incremental reextracted=3; no-op; delete / rename /
#                       dirty / untracked; >30% → full; unknown indexed_commit → full; meta written last; lock
#   5. detach + spawn   update --detach and a stale brief both bring indexed_commit to HEAD in ≤10 s
#   6. git hooks        opt-in install after the shebang (keeps an existing `exit 0` hook), idempotent, post-merge /
#                       post-rewrite / post-checkout refresh ≤10 s, linked worktree skipped, core.hooksPath / husky /
#                       lefthook / non-shell hook → instructions only, uninstall leaves foreign content
#   7. degraded         no python3 → `index: unavailable`; no plane → one line, nothing created; links stub; memory
#   8. ewallet (report) read-only clone of one ewallet service: counts, test -f rate, extraction time, mtimes
#                       (INDEX_EWALLET_SVC=<repo>, default va-ms; skipped when absent or INDEX_NO_EWALLET=1)
#
# Run: evals/regress/index-tests.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CLI="$ROOT/bin/claudehut-index"
FX="$ROOT/evals/fixtures/index"
EW="${INDEX_EWALLET_SVC:-/Users/taiphan/Documents/Projects/ewallet-workspace/va-ms}"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
unset CLAUDE_PROJECT_DIR CLAUDEHUT_HUB CLAUDEHUT_SESSION_ID CLAUDEHUT_INDEX_NO_SPAWN CLAUDEHUT_INDEX_TEST_FAIL
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; }
chk() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
W="$(cd "$W" && pwd -P)"
export TMPDIR="$W/tmp" CLAUDE_PLUGIN_DATA="$W/plugin-data"; mkdir -p "$TMPDIR"

git_init() { git init -q -b main "$1" && git -C "$1" config commit.gpgsign false; }
commit_all() { git -C "$1" add -A && git -C "$1" commit -qm "$2" --no-verify; }
# build <dir> → fixture repo with an (untracked) plane, one commit
build() {
  rm -rf "$1"; git_init "$1"; cp -R "$FX/spring-mini/." "$1/"
  commit_all "$1" base; mkdir -p "$1/.claude/claudehut"
}
sha() { python3 -c 'import hashlib,sys; print(hashlib.sha1(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }
ix() { local r="$1"; shift; OUT="$(cd "$r" && "$CLI" "$@" 2>"$W/stderr")"; RC=$?; }
meta() { jq -r "$2" "$1/.claude/claudehut/index/meta.json" 2>/dev/null; }
comps() { jq -s "$2" "$1/.claude/claudehut/index/components.jsonl" 2>/dev/null; }
head_of() { git -C "$1" rev-parse HEAD; }
# snap <dir> → every file/dir mtime_ns under <dir> (incl. .git), sorted
snap() { python3 - "$1" <<'PY'
import os, sys
root = sys.argv[1]
for d, ds, fs in os.walk(root):
    for n in sorted(ds + fs):
        p = os.path.join(d, n)
        try:
            print(os.lstat(p).st_mtime_ns, os.path.relpath(p, root))
        except OSError:
            pass
PY
}
wait_for() { # <seconds> <condition>
  local i=0 n=$(( $1 * 10 ))
  while [ $i -lt $n ]; do eval "$2" && return 0; python3 -c 'import time; time.sleep(0.1)'; i=$((i+1)); done
  return 1
}
probe() { # <repo> <file c|k> <jq predicate>
  if [ "$2" = c ]; then jq -se "$3" "$1/.claude/claudehut/index/components.jsonl" >/dev/null 2>&1
  else jq -e "$3" "$1/.claude/claudehut/index/contracts.json" >/dev/null 2>&1; fi
}

# ---------------------------------------------------------------- 1. extraction
echo "== 1. extraction =="
R="$W/r1"; build "$R"
ix "$R" update
chk "full update: exit 0, one summary line" '[ "$RC" = 0 ] && [[ "$OUT" == "index: updated full "* ]]'
chk "meta.json: schema 1, indexed_commit = HEAD (40 hex), tool_version, counts.total" \
  '[ "$(meta "$R" .schema)" = 1 ] && [ "$(meta "$R" .indexed_commit)" = "$(head_of "$R")" ] && [ -n "$(meta "$R" .tool_version)" ] && [ "$(meta "$R" .counts.total)" -gt 20 ]'
chk "meta.json stays small: no files/dirty maps (they live in index/files.json), indexed_commit within the first 1 KB" \
  'jq -e "(has(\"files\") or has(\"dirty\")) | not" "$R/.claude/claudehut/index/meta.json" >/dev/null && jq -e ".files|length > 10" "$R/.claude/claudehut/index/files.json" >/dev/null && head -c 1024 "$R/.claude/claudehut/index/meta.json" | grep -q "\"indexed_commit\": \"$(head_of "$R")\""'
chk "index/.gitignore ignores the generated data" '[ "$(cat "$R/.claude/claudehut/index/.gitignore")" = "*" ]'
while IFS=$'\t' read -r rule file pred; do
  case "$rule" in ''|'#'*) continue ;; esac
  chk "probe $rule" 'probe "$R" "$file" "$pred"'
done < "$FX/probes.tsv"
chk "every rule tag of extract.py has a probe and vice versa" \
  '[ "$(grep -oE "# rule:[a-z][a-z-]*$" "$ROOT/scripts/index/extract.py" | sed "s/# rule://" | sort)" = "$(grep -vE "^#|^$" "$FX/probes.tsv" | cut -f1 | sort)" ]'
chk "row shape: id kind name file line on every row; ids unique" \
  '[ "$(comps "$R" "[.[] | select((.id|type)==\"string\" and (.kind|type)==\"string\" and (.name|type)==\"string\" and (.file|type)==\"string\" and (.line|type)==\"number\")] | length")" = "$(comps "$R" length)" ] && [ "$(comps "$R" "[.[].id] | unique | length")" = "$(comps "$R" length)" ]'
nbad=0; nrow=0
while IFS=$'\t' read -r kind file line; do
  nrow=$((nrow+1))
  [ -f "$R/$file" ] || { nbad=$((nbad+1)); continue; }
  txt="$(sed -n "${line}p" "$R/$file")"
  case "$kind" in
    endpoint) pat='Mapping' ;; listener) pat='@KafkaListener' ;; producer) pat='\.send' ;; router) pat='@Bean' ;;
    migration) pat='CREATE TABLE' ;; *) pat='^@|class |interface |record ' ;;
  esac
  printf '%s' "$txt" | grep -qE "$pat" || { nbad=$((nbad+1)); echo "    bad line: $kind $file:$line → $txt"; }
done < <(jq -r '[.kind,.file,(.line|tostring)] | @tsv' "$R/.claude/claudehut/index/components.jsonl")
chk "AC-4: $nrow/$nrow rows pass test -f and point at their annotation / call line" '[ "$nrow" -gt 0 ] && [ "$nbad" = 0 ]'
chk "negative: the '// @Service' comment, the DTO record, src/test and the nested record produce nothing" \
  '[ "$(comps "$R" "[.[] | select(.name==\"OrderDto\" or .name==\"OrderControllerTest\" or (.file|test(\"src/test/\")))] | length")" = 0 ] && [ "$(comps "$R" "[.[] | select(.kind==\"service\")] | length")" = 2 ] && comps "$R" "any(.[]; .name==\"OrderService\" and .methods==[\"create\",\"find\"])" | grep -q true'
chk "negative: an abstract class whose type parameter is bounded by R2dbcRepository is not a repository" \
  '[ "$(comps "$R" "[.[] | select(.name==\"AbstractCrudService\")] | length")" = 0 ]'
chk "a same-file constant path resolves (@GetMapping(value = PATH))" 'probe "$R" c "any(.[]; .http=={\"method\":\"GET\",\"path\":\"/legacy/home\"})"'
chk "a string holding // is not a comment (NOTE field keeps the class parse intact)" 'probe "$R" c "[.[] | select(.name|startswith(\"OrderController#\"))] | length == 6"'
cp "$R/.claude/claudehut/index/components.jsonl" "$W/c1.jsonl"
ix "$R" update --full
chk "deterministic: a second full update writes identical components.jsonl" 'cmp -s "$W/c1.jsonl" "$R/.claude/claudehut/index/components.jsonl"'
chk "no __pycache__ written into the plugin" '[ -z "$(find "$ROOT/scripts/index" -name __pycache__ 2>/dev/null)" ]'
chk "contracts.json: http_exposed mirrors the endpoints (M6 hub-sync input)" \
  '[ "$(jq ".http_exposed | length" "$R/.claude/claudehut/index/contracts.json")" = 7 ] && jq -e ".kafka_consume | length == 2" "$R/.claude/claudehut/index/contracts.json" >/dev/null'

chk "a package named out/ (hexagonal adapter/out/persistence) is source, not build output" \
  'probe "$R" c "any(.[]; .name==\"OrderPersistenceAdapter\" and .kind==\"component\")"'

# ---------------------------------------------------------------- 2. rule removal
echo "== 2. rule removal (mutants) =="
if [ "${INDEX_NO_MUTANTS:-0}" = 1 ]; then
  echo "  (skipped: INDEX_NO_MUTANTS=1)"
else
  M="$W/mut"; mkdir -p "$M/scripts/index" "$M/bin"; cp "$CLI" "$M/bin/"; cp "$ROOT/scripts/index/claudehut_index.py" "$M/scripts/index/"
  RM="$W/rm"; build "$RM"
  while IFS=$'\t' read -r rule file pred; do
    case "$rule" in ''|'#'*) continue ;; esac
    grep -v -E "# rule:$rule\$" "$ROOT/scripts/index/extract.py" > "$M/scripts/index/extract.py"
    rm -rf "$RM/.claude/claudehut/index"
    (cd "$RM" && "$M/bin/claudehut-index" update --full >/dev/null 2>&1)
    chk "mutant -$rule: its probe fails" '! probe "$RM" "$file" "$pred"'
  done < "$FX/probes.tsv"
fi

# ---------------------------------------------------------------- 3. read-only
echo "== 3. read commands are read-only =="
mkdir -p "$R/.understand-anything"; printf '{"gitCommitHash":"%s"}\n' "$(head_of "$R")" > "$R/.understand-anything/meta.json"
printf '{"nodes":[]}\n' > "$R/.understand-anything/knowledge-graph.json"
cp "$FX/reuse-index.json" "$R/.claude/claudehut/reuse-index.json"
ua_before="$(snap "$R/.understand-anything"; sha "$R/.understand-anything/meta.json"; sha "$R/.understand-anything/knowledge-graph.json")"
ri_before="$(sha "$R/.claude/claudehut/reuse-index.json")"
ix "$R" update --full; ix "$R" update
before="$(snap "$R")"
for c in "status" "status --json" "status --fast --json" "brief order create" "brief --budget 500" "find order" \
         "find --kind endpoint search" "find orders.*" "svc" "svc --json" "svc other-ms" "links" "links --json"; do
  # shellcheck disable=SC2086
  ix "$R" $c
  [ "$RC" = 0 ] && [ -n "$OUT" ] || bad "read '$c': rc=$RC, empty output"
done
after="$(snap "$R")"
chk "AC-7: 13 read commands on a fresh index change no mtime in the repo (incl. .git/index)" '[ "$before" = "$after" ]'
chk "AC-4: reuse-index.json checksum unchanged by update --full, update and every read" '[ "$(sha "$R/.claude/claudehut/reuse-index.json")" = "$ri_before" ]'
chk "never writes .understand-anything/ (mtimes + checksums unchanged across updates and reads)" \
  '[ "$(snap "$R/.understand-anything"; sha "$R/.understand-anything/meta.json"; sha "$R/.understand-anything/knowledge-graph.json")" = "$ua_before" ]'
ix "$R" find tariff
chk "legacy reuse-index read-through: find matches a v0.11 tag of an existing path; a dead path is ignored" \
  '[[ "$OUT" == "service com.acme.shop.service.PricingService "*"Legacy note: computes list prices for a sku."* ]] && [[ "$(cd "$R" && "$CLI" find ghosttag)" == "index: no component matches"* ]]'

ix "$R" status --json
chk "status --json: fresh, behind 0, dirty 0, not updating, mode mono, language en, hub null, ua behind 0" \
  'jq -e ".stale==false and .behind==0 and .dirty==0 and .updating==false and .mode==\"mono\" and .language==\"en\" and .hub==null and (.head|length)==40 and .ua.dir==\".understand-anything\" and .ua.behind==0" <<<"$OUT" >/dev/null'
ix "$R" brief --budget 400 order
chk "brief --budget 400 → ≤400 bytes, starts with the index banner" '[ "$(printf "%s" "$OUT" | wc -c | tr -d " ")" -le 400 ] && [[ "$OUT" == "Index r1@"*"(fresh)"* ]]'
ix "$R" brief --json order create
chk "brief --json: the shared contract {budget, bytes, sections, markdown}; sections hold exactly the markdown lines" \
  'jq -e "(keys==[\"budget\",\"bytes\",\"markdown\",\"sections\"]) and .budget==3000 and .bytes<=3000 and (.markdown|startswith(\"Index r1@\")) and ([.sections[]|select(.name==\"top\")][0].rows|length)>0 and ([.sections[].lines[]]|join(\"\\n\"))==.markdown" <<<"$OUT" >/dev/null'
ix "$R" brief --json --budget 400 order
chk "brief --json --budget 400: clipped, the trailer is a 'more' section, sections still join to the markdown" \
  'jq -e ".bytes<=400 and (.sections|last|.name)==\"more\" and ([.sections[].lines[]]|join(\"\\n\"))==.markdown" <<<"$OUT" >/dev/null'
ix "$R" brief order create
chk "brief (default 3000): ≤3000 B, ranks OrderController#create first, lists contracts" \
  '[ "$(printf "%s" "$OUT" | wc -c | tr -d " ")" -le 3000 ] && [ "$(printf "%s\n" "$OUT" | grep -m1 "^- ")" != "" ] && printf "%s\n" "$OUT" | grep -m1 "^- " | grep -q "OrderController#create" && printf "%s" "$OUT" | grep -q "^Contracts:"'
chk "brief: a listener/producer row is listed once, under Contracts only" \
  '[ -z "$(printf "%s\n" "$OUT" | grep "^- " | sort | uniq -d)" ] && [ -z "$(printf "%s\n" "$OUT" | sed -n "/^Top components:/,/^Contracts:/p" | grep -E "^- (listener|producer) ")" ] && printf "%s\n" "$OUT" | sed -n "/^Contracts:/,\$p" | grep -qE "^- (listener|producer) "'
mkdir -p "$R/.claude/claudehut/tasks/0001-pricing-rules"
printf '{"schema":2,"id":"0001-pricing-rules","slug":"pricing-rules"}\n' > "$R/.claude/claudehut/tasks/0001-pricing-rules/task.json"
ix "$R" brief --task 0001-pricing-rules
chk "brief --task ID takes its terms from the task (PricingService first)" 'printf "%s\n" "$OUT" | grep -m1 "^- " | grep -q PricingService'
chk "brief --task ID: a known task prints no 'not found' line" '! printf "%s\n" "$OUT" | grep -q "not found"'
ix "$R" brief --task 0099-nope order
chk "brief --task <unknown id>: one line 'task <id> not found — generic brief', then the generic brief" \
  '[ "$(printf "%s\n" "$OUT" | grep -c "^task 0099-nope not found — generic brief$")" = 1 ] && printf "%s\n" "$OUT" | grep -q "^Top components:"'
ix "$R" svc
chk "svc ≤2500 B with endpoints, kafka, clients, tables, db, libs" \
  '[ "$(printf "%s" "$OUT" | wc -c | tr -d " ")" -le 2500 ] && for w in "Endpoints (7)" "Kafka: consumes" "Clients:" "Tables:" "DB: shop" "Libs:"; do printf "%s" "$OUT" | grep -qF "$w" || exit 1; done'
ix "$R" find order --kind endpoint --json
chk "find --kind endpoint --json → JSON array of endpoint rows only" 'jq -e "length==6 and all(.[]; .kind==\"endpoint\")" <<<"$OUT" >/dev/null'
# stale, spawn disabled: banner + still read-only
printf '// touch\n' >> "$R/src/main/java/com/acme/shop/config/KafkaConfig.java"; commit_all "$R" "stale 1"
before="$(snap "$R")"
OUT="$(cd "$R" && CLAUDEHUT_INDEX_NO_SPAWN=1 "$CLI" brief order)"
OUT2="$(cd "$R" && CLAUDEHUT_INDEX_NO_SPAWN=1 "$CLI" svc)"
after="$(snap "$R")"
chk "stale brief/svc (spawn off): banner 'stale: 1 commit(s) behind', no mtime changes" \
  '[[ "$OUT" == *"(stale: 1 commit(s) behind)"* ]] && [[ "$OUT2" == *"stale: 1 commit(s) behind"* ]] && [ "$before" = "$after" ]'
printf '{"schema":1,"mode":"mono","hub":null,"language":"vi","shared":false,"git_hooks":false}\n' > "$R/.claude/claudehut/topology.json"
OUT="$(cd "$R" && CLAUDEHUT_INDEX_NO_SPAWN=1 "$CLI" brief --budget 300 order)"
chk "language vi (topology.json): banner 'lệch 1 commit', budget counted in bytes (≤300)" \
  '[[ "$OUT" == *"lệch 1 commit"* ]] && [ "$(printf "%s" "$OUT" | wc -c | tr -d " ")" -le 300 ]'
rm -f "$R/.claude/claudehut/topology.json"

# ---------------------------------------------------------------- 4. freshness
echo "== 4. freshness / incremental update =="
R="$W/r2"; build "$R"; ix "$R" update; base="$(head_of "$R")"
J="$R/src/main/java/com/acme/shop"
perl -0pi -e 's|(  \@DeleteMapping)|  \@GetMapping("/{id}/lines")\n  public String lines(\@PathVariable String id) {\n    return id;\n  }\n\n$1|' "$J/controller/OrderController.java"
printf '// c1\n' >> "$J/service/PricingService.java"; commit_all "$R" c1
printf '// c2\n' >> "$J/entity/Order.java"; commit_all "$R" c2
ix "$R" status --json
chk "AC-5: after 2 commits → behind 2, stale, indexed_commit still the old sha" \
  'jq -e --arg b "$base" ".behind==2 and .stale==true and .indexed_commit==\$b" <<<"$OUT" >/dev/null'
ix "$R" update --json
chk "AC-5: incremental update → reextracted=3, indexed_commit = HEAD" \
  'jq -e --arg h "$(head_of "$R")" ".mode==\"incremental\" and .reextracted==3 and .indexed_commit==\$h" <<<"$OUT" >/dev/null'
chk "the new endpoint is found at its line" 'probe "$R" c "any(.[]; .http=={\"method\":\"GET\",\"path\":\"/api/orders/{id}/lines\"} and .line==37)"'
ix "$R" update
chk "no-op when indexed == HEAD and nothing dirty" '[[ "$OUT" == "index: up to date"* ]]'
git -C "$R" rm -q "$J/support/AuditAspect.java"; git -C "$R" mv "$J/config/KafkaConfig.java" "$J/config/KafkaSetup.java"
sed -i.bak 's/class KafkaConfig/class KafkaSetup/' "$J/config/KafkaSetup.java" && rm -f "$J/config/KafkaSetup.java.bak"; commit_all "$R" "delete+rename"
ix "$R" update --json
chk "delete + rename: AuditAspect gone, KafkaConfig → KafkaSetup at the new path" \
  'probe "$R" c "(any(.[]; .name==\"AuditAspect\") | not) and (any(.[]; .name==\"KafkaConfig\") | not) and any(.[]; .name==\"KafkaSetup\" and (.file|endswith(\"KafkaSetup.java\")))"'
mkdir -p "$J/extra"; printf 'package com.acme.shop.extra;\n\n@org.springframework.stereotype.Service\npublic class DraftService {}\n' > "$J/extra/DraftService.java"
ix "$R" status --json
chk "untracked java file → status dirty=1 (index not stale by commit)" 'jq -e ".dirty==1 and .behind==0" <<<"$OUT" >/dev/null'
ix "$R" update --json
chk "update picks up the untracked file (reextracted=1); status dirty=0 afterwards" \
  'jq -e ".reextracted==1" <<<"$OUT" >/dev/null && probe "$R" c "any(.[]; .name==\"DraftService\")" && [ "$(cd "$R" && "$CLI" status --json | jq .dirty)" = 0 ]'
rm -rf "$J/extra"; ix "$R" update
chk "a dirty file indexed earlier and then removed drops out (meta.dirty candidates)" '! probe "$R" c "any(.[]; .name==\"DraftService\")"'
for f in controller/LegacyController service/OrderService service/PricingService entity/Customer repository/CustomerDao client/PaymentClient; do
  printf '// wide\n' >> "$J/$f.java"; done; commit_all "$R" wide
ix "$R" update --json
chk ">30% of the indexed files changed → full update" 'jq -e ".mode==\"full\" and (.reason|test(\"30%\"))" <<<"$OUT" >/dev/null'
jq '.indexed_commit="0000000000000000000000000000000000000001"' "$R/.claude/claudehut/index/meta.json" > "$W/m.json" && cp "$W/m.json" "$R/.claude/claudehut/index/meta.json"
ix "$R" update --json
chk "unknown indexed_commit → full update" 'jq -e ".mode==\"full\" and .reason==\"indexed_commit unknown\"" <<<"$OUT" >/dev/null'
old="$(head_of "$R")"; printf '// c3\n' >> "$J/entity/Order.java"; commit_all "$R" c3
OUT="$(cd "$R" && CLAUDEHUT_INDEX_TEST_FAIL=before-meta "$CLI" update)"
chk "meta.json is written LAST: a failure after the data leaves indexed_commit old → status stale" \
  '[[ "$OUT" == "index: error"* ]] && [ "$(meta "$R" .indexed_commit)" = "$old" ] && [ "$(cd "$R" && "$CLI" status --json | jq .stale)" = true ]'
mkdir "$R/.claude/claudehut/index/.lock"
ix "$R" update
chk "a fresh lock → update skipped with one line, exit 0" '[ "$RC" = 0 ] && [[ "$OUT" == *"skipped"* ]] && [ "$(meta "$R" .indexed_commit)" = "$old" ]'
ix "$R" status --json
chk "status reports updating=true while the lock is fresh" 'jq -e ".updating==true" <<<"$OUT" >/dev/null'
touch -t 202001010000 "$R/.claude/claudehut/index/.lock"
ix "$R" update
chk "a lock older than 120 s is taken over; lock released afterwards" \
  '[ "$(meta "$R" .indexed_commit)" = "$(head_of "$R")" ] && [ ! -e "$R/.claude/claudehut/index/.lock" ]'

# ---------------------------------------------------------------- 5. detach + spawn
echo "== 5. detached update =="
printf '// d1\n' >> "$J/entity/Order.java"; commit_all "$R" d1
t0=$(python3 -c 'import time; print(time.time())'); ix "$R" update --detach
t1=$(python3 -c 'import time; print(time.time())')
chk "update --detach returns immediately (<1 s) with one line" \
  '[ "$OUT" = "index: update started in background" ] && python3 -c "import sys; sys.exit(0 if $t1-$t0 < 1 else 1)"'
chk "…and the background update reaches HEAD in ≤10 s" 'wait_for 10 "[ \"\$(meta \"$R\" .indexed_commit)\" = \"\$(head_of \"$R\")\" ]"'
wait_for 5 '[ ! -e "$R/.claude/claudehut/index/.lock" ]'
printf '// d2\n' >> "$J/entity/Order.java"; commit_all "$R" d2
ix "$R" brief order
chk "a stale brief shows 'updating in background' and the spawned update reaches HEAD in ≤10 s" \
  '[[ "$OUT" == *"updating in background"* ]] && wait_for 10 "[ \"\$(meta \"$R\" .indexed_commit)\" = \"\$(head_of \"$R\")\" ]"'
wait_for 5 '[ ! -e "$R/.claude/claudehut/index/.lock" ]'

# ---------------------------------------------------------------- 6. git hooks
echo "== 6. git hooks (opt-in) =="
R="$W/r3"; build "$R"
printf '{"schema":1,"mode":"mono","hub":null,"language":"en","shared":false,"git_hooks":false}\n' > "$R/.claude/claudehut/topology.json"
git -C "$R" add -f .claude/claudehut/topology.json && git -C "$R" commit -qm plane --no-verify
ix "$R" update
H="$R/.git/hooks"; printf '#!/bin/sh\necho mine\nexit 0\n' > "$H/post-merge"; chmod +x "$H/post-merge"
ix "$R" install-git-hooks
chk "install: post-merge, post-rewrite, post-checkout written; topology.json git_hooks=true" \
  '[ -x "$H/post-merge" ] && [ -x "$H/post-rewrite" ] && [ -x "$H/post-checkout" ] && jq -e ".git_hooks==true" "$R/.claude/claudehut/topology.json" >/dev/null'
chk "existing hook: block inserted right after the shebang, before its 'exit 0'; foreign lines kept" \
  '[ "$(sed -n 2p "$H/post-merge")" = "# >>> claudehut-index >>>" ] && grep -q "^echo mine$" "$H/post-merge" && [ "$(tail -1 "$H/post-merge")" = "exit 0" ]'
chk "the block never exits and calls the shim in \$CLAUDE_PLUGIN_DATA/bin" \
  '! sed -n "/>>> claudehut-index/,/<<< claudehut-index/p" "$H/post-merge" | grep -qE "(^|[^a-z])exit([^a-z]|$)" && grep -q "$CLAUDE_PLUGIN_DATA/bin/claudehut-index" "$H/post-merge" && [ -x "$CLAUDE_PLUGIN_DATA/bin/claudehut-index" ]'
chk "every hook passes sh -n" 'for h in post-merge post-rewrite post-checkout; do sh -n "$H/$h" || exit 1; done'
ix "$R" install-git-hooks
chk "idempotent: a second install leaves exactly one block per hook" \
  'for h in post-merge post-rewrite post-checkout; do [ "$(grep -c ">>> claudehut-index >>>" "$H/$h")" = 1 ] || exit 1; done'
printf '#!/bin/sh\nt=/old/plugin/1.0/bin/claudehut-index\n' > "$CLAUDE_PLUGIN_DATA/bin/claudehut-index"
ix "$R" update
chk "update re-points a stale shim (plugin upgrade) at the current CLI" 'grep -qF "t='"'"'$CLI'"'"'" "$CLAUDE_PLUGIN_DATA/bin/claudehut-index"'
git -C "$R" checkout -q -b topic; printf '// m1\n' >> "$R/src/main/java/com/acme/shop/entity/Order.java"; commit_all "$R" m1
wait_for 5 '[ ! -e "$R/.claude/claudehut/index/.lock" ]'
git -C "$R" checkout -q main; wait_for 5 '[ ! -e "$R/.claude/claudehut/index/.lock" ]'
git -C "$R" merge -q --ff-only topic >/dev/null 2>&1
chk "AC-5: post-merge (git merge) → indexed_commit = HEAD in ≤10 s" 'wait_for 10 "[ \"\$(meta \"$R\" .indexed_commit)\" = \"\$(head_of \"$R\")\" ]"'
wait_for 5 '[ ! -e "$R/.claude/claudehut/index/.lock" ]'
printf '// amend\n' >> "$R/src/main/java/com/acme/shop/entity/Order.java"; git -C "$R" add -A; git -C "$R" commit -q --amend --no-edit
chk "post-rewrite (commit --amend, as pull --rebase) → indexed_commit = HEAD in ≤10 s" 'wait_for 10 "[ \"\$(meta \"$R\" .indexed_commit)\" = \"\$(head_of \"$R\")\" ]"'
wait_for 5 '[ ! -e "$R/.claude/claudehut/index/.lock" ]'
git -C "$R" worktree add -q "$W/r3-wt" -b wt-branch 2>/dev/null
python3 -c 'import time; time.sleep(1.5)'
chk "linked worktree: post-checkout fires there but the block skips it (no index in the worktree plane)" \
  '[ -d "$W/r3-wt/.claude/claudehut" ] && [ ! -e "$W/r3-wt/.claude/claudehut/index" ]'
printf '// scratch\n' >> "$R/src/main/java/com/acme/shop/entity/Order.java"
git -C "$R" checkout -- src/main/java/com/acme/shop/entity/Order.java; rc_co=$?
printf '// scratch\n' >> "$R/src/main/java/com/acme/shop/entity/Order.java"
git -C "$R" restore src/main/java/com/acme/shop/entity/Order.java; rc_rs=$?
(cd "$R" && sh .git/hooks/post-checkout a b 0); rc_h0=$?
chk "file checkout: 'git checkout -- f' and 'git restore f' exit 0 with post-checkout installed (\$3=0)" \
  '[ "$rc_co" = 0 ] && [ "$rc_rs" = 0 ] && [ "$rc_h0" = 0 ]'
wait_for 5 '[ ! -e "$R/.claude/claudehut/index/.lock" ]'
ix "$R" uninstall-git-hooks
chk "uninstall: block gone, foreign post-merge kept intact, hooks we created deleted, git_hooks=false" \
  '[ "$(cat "$H/post-merge")" = "$(printf "#!/bin/sh\necho mine\nexit 0")" ] && [ ! -e "$H/post-rewrite" ] && [ ! -e "$H/post-checkout" ] && jq -e ".git_hooks==false" "$R/.claude/claudehut/topology.json" >/dev/null'
for mgr in hooksPath husky lefthook; do
  R="$W/r4-$mgr"; build "$R"
  case "$mgr" in hooksPath) git -C "$R" config core.hooksPath .githooks ;; husky) mkdir -p "$R/.husky" ;; lefthook) : > "$R/lefthook.yml" ;; esac
  before="$(ls -A "$R/.git/hooks" | grep -v '\.sample$' | sort)"
  ix "$R" install-git-hooks
  chk "AC-13: $mgr → only instructions printed, no hook written" \
    '[[ "$OUT" == *"nothing written"* ]] && [[ "$OUT" == *">>> claudehut-index >>>"* ]] && [ "$(ls -A "$R/.git/hooks" | grep -v "\.sample$" | sort)" = "$before" ] && [ ! -e "$R/.githooks" ]'
done
R="$W/r5"; build "$R"; printf '#!/usr/bin/env python3\nprint(1)\n' > "$R/.git/hooks/post-checkout"
ix "$R" install-git-hooks
chk "a non-shell hook is left alone and reported for manual edit" \
  '[[ "$OUT" == *"post-checkout not a shell script"* ]] && ! grep -q claudehut "$R/.git/hooks/post-checkout" && [ -x "$R/.git/hooks/post-merge" ]'

# ---------------------------------------------------------------- 7. degraded
echo "== 7. degraded paths =="
OUT="$(CLAUDEHUT_PYTHON=/nonexistent/python3 "$CLI" status)"; RC=$?
chk "no python3 → 'index: unavailable', exit 0" '[ "$RC" = 0 ] && [ "$OUT" = "index: unavailable" ]'
R="$W/r6"; rm -rf "$R"; git_init "$R"; printf 'x\n' > "$R/a"; commit_all "$R" a
for c in status brief find svc update links; do
  ix "$R" $c x
  [ "$RC" = 0 ] && [ "$(printf '%s\n' "$OUT" | grep -c .)" -le 2 ] || bad "no plane: '$c' rc=$RC out=$OUT"
done
chk "no plane: 6 commands exit 0 and create nothing" '[ ! -e "$R/.claude" ]'
ix "$W/r1" links
chk "links (M6 stub) → 'n/a — hub not configured'" '[ "$OUT" = "n/a — hub not configured" ]'
ix "$W/r1" bogus
chk "unknown command → one line, exit 0" '[ "$RC" = 0 ] && [[ "$OUT" == "index: unknown command"* ]]'
ix "$W/r1" memory
if [ -f "$ROOT/scripts/index/memory.py" ]; then
  chk "memory delegates to scripts/index/memory.py (exit 0)" '[ "$RC" = 0 ] && [ -n "$OUT" ]'
else
  chk "memory without scripts/index/memory.py → one line, exit 0" '[ "$RC" = 0 ] && [ "$OUT" = "index: memory generator unavailable" ]'
fi

# ---------------------------------------------------------------- 8. ewallet (report)
echo "== 8. ewallet service (read-only clone) =="
if [ "${INDEX_NO_EWALLET:-0}" = 1 ] || [ ! -d "$EW/.git" ]; then
  echo "  (skipped: ${EW} not available)"
else
  src_before="$(python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_mtime_ns)' "$EW/.git/index" 2>/dev/null)"
  E="$W/ew"; git clone -q --no-hardlinks "$EW" "$E" 2>/dev/null
  mkdir -p "$E/.claude/claudehut"
  t0=$(python3 -c 'import time; print(time.time())'); ix "$E" update --json; t1=$(python3 -c 'import time; print(time.time())')
  echo "  report: $(basename "$EW")@$(git -C "$E" rev-parse --short HEAD) $(jq -c .counts <<<"$OUT") elapsed_ms=$(jq .elapsed_ms <<<"$OUT") wall=$(python3 -c "print(round($t1-$t0,2))")s"
  n=0; nb=0
  while IFS= read -r f; do n=$((n+1)); [ -f "$E/$f" ] || nb=$((nb+1)); done < <(jq -r .file "$E/.claude/claudehut/index/components.jsonl")
  echo "  report: test -f $((n-nb))/$n"
  chk "ewallet: 100% of $n rows pass test -f" '[ "$n" -gt 0 ] && [ "$nb" = 0 ]'
  chk "ewallet: endpoints, listeners, entities and migrations extracted" \
    'jq -e ".counts.endpoint>0 and .counts.listener>0 and .counts.entity>0 and .counts.migration>0" <<<"$OUT" >/dev/null'
  chk "ewallet: full extraction ≤10 s" '[ "$(jq .elapsed_ms <<<"$OUT")" -le 10000 ]'
  before="$(snap "$E")"
  for c in "status --json" "brief refund" "find Refund" "svc"; do
    # shellcheck disable=SC2086
    ix "$E" $c
  done
  after="$(snap "$E")"
  chk "ewallet: read commands keep every mtime of the clone" '[ "$before" = "$after" ]'
  chk "ewallet: the source repo's .git/index was not touched" \
    '[ "$src_before" = "$(python3 -c "import os,sys; print(os.stat(sys.argv[1]).st_mtime_ns)" "$EW/.git/index" 2>/dev/null)" ]'
  ix "$E" brief refund
  echo "  report: brief refund = $(printf '%s\n' "$OUT" | wc -c | tr -d ' ') B; svc = $(cd "$E" && "$CLI" svc | wc -c | tr -d ' ') B"
fi

echo
echo "INDEX-TESTS: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
