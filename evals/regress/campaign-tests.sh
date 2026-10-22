#!/usr/bin/env bash
# campaign-tests.sh — K8 campaigns (M5c; docs/v0.20 04 §6, 09 §6). The M5 exit simulation: one campaign over THREE
# fixture repos (copies of evals/fixtures/hub/{a-ms,b-ms,c-ms} at HEAD, in temp; the fixtures are never written),
# a temp hub, three sessions.
#   CP1-CP3   create references the template by hash (never copied); SessionStart pulls one line in a target repo
#             and nothing elsewhere; a non-target repo cannot start a child task
#   CP4-CP7   start --campaign makes a normal task carrying campaign_id + template_rev and takes the lease; a second
#             session on the same repo is refused (task.json untouched); the lease frees on end; an expired lease is
#             taken over
#   CP8-CP11  the aggregate: done / waiting-approval / blocked across the three repos, from mirrored events alone
#   CP12-CP13 a template change drifts the unfinished children only; a mirror retry leaves the hub byte-identical
#   CP14      the bash writer refuses --campaign with its way out (campaigns need the Python writer)
# Prints "CAMPAIGN: N passed, M failed"; exit 1 on failure.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
command -v python3 >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || { echo "CAMPAIGN: 0 passed, 0 failed (no python3/jq)"; exit 0; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/campaign tests.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS+1)); echo "ok - $1"; else FAIL=$((FAIL+1)); echo "FAIL - $1"; fi; }
export CLAUDEHUT_HOST_PROBE=0 CLAUDEHUT_INDEX_NO_SPAWN=1
unset CLAUDEHUT_PACKS CLAUDEHUT_GATE_MODE CLAUDEHUT_STATE_IMPL
K="$ROOT/bin/claudehut-kernel"; CS="$ROOT/bin/claudehut-state"

H="$TMP/hub-root"; mkdir -p "$H/.claudehut/hub" "$H/prompts"; printf '{"schema":1}\n' >"$H/.claudehut/hub/hub.json"
printf '# Feature flag rollout\n1. add the flag\n' >"$H/prompts/featureflag.md"
export CLAUDEHUT_HUB="$H"
for r in a-ms b-ms c-ms; do   # tracked files only, at HEAD: the untracked bin/ noise of the fixtures stays out
  mkdir -p "$TMP/ws/$r"
  git -C "$ROOT" archive HEAD "evals/fixtures/hub/$r" | tar -x -C "$TMP/ws/$r" --strip-components=4
  mkdir -p "$TMP/ws/$r/.claudehut/tasks"
  git -C "$TMP/ws/$r" init -q && git -C "$TMP/ws/$r" add -A && git -C "$TMP/ws/$r" -c user.email=t@t -c user.name=t commit -qm i
done
mkdir -p "$TMP/ws/other/.claudehut"; git -C "$TMP/ws/other" init -q
cs() { local r="$1" s="$2"; shift 2; CLAUDE_PROJECT_DIR="$TMP/ws/$r" "$CS" --session "$s" "$@"; }
tj() { cat "$TMP/ws/$1/.claudehut/tasks/$2/task.json"; }
C="$H/.claudehut/hub/campaigns/ff"

"$K" campaign create ff --goal "feature flag on every service" --template prompts/featureflag.md \
  --repo a-ms --repo b-ms --repo c-ms --owner "tech lead" >"$TMP/c.json"; rc=$?
check "CP1: create stores the template by path + sha256 rev, repos in order (rc=$rc)" '[ "$rc" = 0 ] && jq -e ".template.path==\"prompts/featureflag.md\" and (.template.rev|startswith(\"sha256:\")) and ([.repos[].repo]==[\"a-ms\",\"b-ms\",\"c-ms\"])" "$C/campaign.json" >/dev/null && [ ! -e "$C/featureflag.md" ]'
line="$(CLAUDE_PROJECT_DIR="$TMP/ws/a-ms" "$K" campaign pending --project "$TMP/ws/a-ms")"
other="$(CLAUDE_PROJECT_DIR="$TMP/ws/other" "$K" campaign pending --project "$TMP/ws/other")"
check "CP2: pending: one line in a target repo (start command named), nothing elsewhere" '[[ "$line" == "Campaign work for this repo"*"claudehut-state start --campaign ff"* ]] && [ -z "$other" ]'
boot="$(cd "$TMP/ws/a-ms" && printf '{"session_id":"boot1","source":"startup","cwd":"%s"}' "$TMP/ws/a-ms" | CLAUDE_PROJECT_DIR="$TMP/ws/a-ms" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$ROOT/scripts/bootstrap.sh" | jq -r '.hookSpecificOutput.additionalContext // empty')"
check "CP2b: the SessionStart context carries that line (per-session block, not the digest)" '[[ "$boot" == *"Campaign work for this repo"* ]] && ! grep -q "Campaign work" "$ROOT/skills/claudehut-workflow/references/digest.md"'
cs other o1 start --route light --slug x --campaign ff 2>"$TMP/err"; rc=$?
check "CP3: a repo that is not a target cannot start a child task (rc=$rc)" '[ "$rc" != 0 ] && grep -q "is not a target of ff" "$TMP/err"'

ida="$(cs a-ms sa start --route light --slug ff --campaign ff 2>"$TMP/err" | head -1)"
check "CP4: start --campaign makes a normal task with campaign_id, repo and template_rev" 'tj a-ms "$ida" | jq -e --arg r "$(jq -r .template.rev "$C/campaign.json")" ".campaign_id==\"ff\" and .campaign_repo==\"a-ms\" and .campaign_template_rev==\$r and .status==\"active\"" >/dev/null && grep -q "template prompts/featureflag.md@" "$TMP/err"'
check "CP5: the lease is held by that session and its events are mirrored" 'jq -e ".session==\"sa\"" "$C/repos/a-ms/lease.json" >/dev/null && [ -s "$C/repos/a-ms/events.jsonl" ]'
cs a-ms sb start --route light --slug ff2 --campaign ff 2>"$TMP/err"; rc=$?
check "CP6: a second session on the same repo is refused by the lease (rc=$rc), no task created" '[ "$rc" != 0 ] && grep -q "leased by session sa" "$TMP/err" && [ "$(ls "$TMP/ws/a-ms/.claudehut/tasks" | wc -l | tr -d " ")" = 1 ]'

idb="$(cs b-ms sb start --route light --slug ff --campaign ff 2>/dev/null | head -1)"
python3 - "$C/repos/b-ms/lease.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["expires"] = 1.0; json.dump(d, open(p, "w"))
PY
idb2="$(cs b-ms sc start --route light --slug ff-takeover --campaign ff 2>/dev/null | head -1)"
check "CP7a: an expired lease is taken over by another session" '[ -n "$idb2" ] && jq -e ".session==\"sc\"" "$C/repos/b-ms/lease.json" >/dev/null'
# b-ms (session sc): reviewed → waiting for the owner's approval
mkdir -p "$TMP/ws/b-ms/.claudehut/tasks/$idb2"
f="$(cd "$TMP/ws/b-ms" && git ls-files | grep -m1 '\.java$')"
printf '# Review\n| Item | Verdict | Locus |\n|---|---|---|\n| AC-1 | ✓ satisfied | %s:1 |\n\n./gradlew test — 1 passed\n' "$f" >"$TMP/ws/b-ms/.claudehut/tasks/$idb2/review.md"
cs b-ms sc set-review pass --evidence ".claudehut/tasks/$idb2/review.md" 2>"$TMP/rv.err" || cat "$TMP/rv.err"
# c-ms (session sd): a refused transition → blocked
idc="$(cs c-ms sd start --route light --slug ff --campaign ff 2>/dev/null | head -1)"
CLAUDEHUT_GATE_MODE=block cs c-ms sd end --status done 2>/dev/null
# a-ms (session sa): done
cs a-ms sa end --status done 2>/dev/null
check "CP7b: the lease is released when the task ends" '[ ! -e "$C/repos/a-ms/lease.json" ]'
"$K" campaign status ff --json >"$TMP/ag.json"
st="$(jq -r '[.repos[] | "\(.repo)=\(.status)"] | join(" ")' "$TMP/ag.json")"
check "CP8: a-ms done (from mirrored events alone)" '[[ "$st" == *"a-ms=done"* ]]'
line="$(CLAUDE_PROJECT_DIR="$TMP/ws/a-ms" "$K" campaign pending --project "$TMP/ws/a-ms")"
lineb="$(CLAUDE_PROJECT_DIR="$TMP/ws/b-ms" "$K" campaign pending --project "$TMP/ws/b-ms")"
check "CP8b: pending goes quiet once the child is done, and names the open task otherwise" '[ -z "$line" ] && [[ "$lineb" == *"ff (task $idb2: waiting-approval)"* ]]'
check "CP9: b-ms waiting-approval (review passed; approval stays with its owner)" '[[ "$st" == *"b-ms=waiting-approval"* ]]'
check "CP10: c-ms blocked (the refused end was mirrored)" '[[ "$st" == *"c-ms=blocked"* ]]'
txt="$("$ROOT/bin/claudehut" status --campaign ff)"
check "CP11: claudehut status --campaign: 1/3 done, 1 blocked, 1 waiting-approval" '[[ "$txt" == "campaign  : ff 1/3 done, 1 blocked, 1 waiting-approval"* ]]'

printf '# Feature flag rollout\n1. add the flag\n2. and its kill switch\n' >"$H/prompts/featureflag.md"
"$K" campaign template ff 2>/dev/null
"$K" campaign status ff --json >"$TMP/ag2.json"
check "CP12: a template change drifts the unfinished children (b-ms, c-ms), not the done one" '[ "$(jq -c "[.repos[]|select(.drifted)|.repo]" "$TMP/ag2.json")" = "[\"b-ms\",\"c-ms\"]" ] && [ "$(jq ".history|length" "$C/campaign.json")" = 1 ]'
before="$(cd "$C" && find . -type f | sort | xargs cat | shasum)"
"$K" campaign mirror --task "$TMP/ws/a-ms/.claudehut/tasks/$ida" 2>/dev/null
"$K" campaign mirror --task "$TMP/ws/c-ms/.claudehut/tasks/$idc" 2>/dev/null
after="$(cd "$C" && find . -type f | sort | xargs cat | shasum)"
check "CP13: a mirror retry leaves the hub byte-identical" '[ "$before" = "$after" ]'

CLAUDEHUT_STATE_IMPL=bash cs other o2 start --route light --slug y --campaign ff 2>"$TMP/err"; rc=$?
check "CP14: the bash writer refuses --campaign and names the way out (rc=$rc)" '[ "$rc" != 0 ] && grep -q "needs the Python state writer" "$TMP/err"'

echo "CAMPAIGN: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
