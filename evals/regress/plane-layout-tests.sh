#!/usr/bin/env bash
# plane-layout-tests.sh — ADR K-18: the plane lives in <repo>/.claudehut/ (outside the protected .claude/), a legacy
# .claude/claudehut/ keeps working until claudehut-migrate-plane moves it.
#   R    the bash resolver (scripts/lib/plane-path.sh) and the Python one (claudehut_kernel/plane.py) agree on every
#        layout: new only, legacy only, both (new wins), none (new)
#   S    claudehut-state on the new layout: start writes .claudehut/tasks/, an artifact under .claudehut/ is accepted,
#        one under the legacy path of the same repo is refused; on a legacy-only repo the legacy path still works
#   M    claudehut-migrate-plane: dry-run writes nothing; apply moves the plane, rewrites only the CLAUDE.md imports,
#        keeps a local plane local; re-run is a no-op; a repo with both layouts is refused
#   G    no hard-coded .claude/claudehut in runtime code outside the resolvers and the legacy-aware sites
# Self-contained temp repos, no network. Prints "PLANE-LAYOUT: N passed, M failed"; exit 1 on failure.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CS="$ROOT/bin/claudehut-state"; MIG="$ROOT/bin/claudehut-migrate-plane"
command -v jq >/dev/null 2>&1 || { echo "PLANE-LAYOUT: jq missing"; exit 1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/plane-layout.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }
export CLAUDEHUT_HOST_PROBE=0

echo "== R: bash and Python resolvers agree =="
. "$ROOT/scripts/lib/plane-path.sh"
py_plane() { python3 -B -c 'import sys; sys.path.insert(0, sys.argv[1]); from claudehut_kernel.plane import plane_dir; print(plane_dir(sys.argv[2]))' "$ROOT/scripts/kernel" "$1"; }
for c in new legacy both none; do
  d="$TMP/r-$c"; mkdir -p "$d"
  case "$c" in new) mkdir -p "$d/.claudehut" ;; legacy) mkdir -p "$d/.claude/claudehut" ;; both) mkdir -p "$d/.claudehut" "$d/.claude/claudehut" ;; esac
  want="$d/.claudehut"; [ "$c" = legacy ] && want="$d/.claude/claudehut"
  b="$(ch_plane_dir "$d")"; p="$(py_plane "$d")"
  [ "$b" = "$want" ] && [ "$p" = "$want" ] && ok "R: $c → ${want#$d/}" || bad "R: $c → bash '$b' python '$p', want '$want'"
done
h="$TMP/hub"; mkdir -p "$h/.claude/claudehut/hub"
[ "$(ch_hub_dir "$h")" = "$h/.claude/claudehut/hub" ] && [ "$(ch_hub_root "$h/.claudehut/hub")" = "$h" ] \
  && [ "$(ch_hub_root "$h/.claude/claudehut/hub")" = "$h" ] && ok "R: hub dir legacy fallback; both inner spellings name the hub root" \
  || bad "R: hub resolver"

echo "== S: claudehut-state on .claudehut/ =="
n="$TMP/s-new"; mkdir -p "$n/.claudehut"
out="$(CLAUDE_PROJECT_DIR="$n" "$CS" --session s1 start --route light --slug add-thing 2>&1)"
id="$(ls "$n/.claudehut/tasks" 2>/dev/null | head -1)"
[ -n "$id" ] && [ -f "$n/.claudehut/tasks/$id/task.json" ] && [ ! -e "$n/.claude/claudehut" ] \
  && ok "S: start writes .claudehut/tasks/$id/ and creates no legacy plane" || bad "S: start on new layout: $out"
case "$out" in *".claudehut/tasks/$id/"*) ok "S: start prints the task dir on the new path" ;; *) bad "S: start printed '$out'" ;; esac
mkdir -p "$n/.claudehut/tasks/$id"; printf '# Spec\n' > "$n/.claudehut/tasks/$id/spec.md"
# The spec has no reuse table, so the verb fails on CONTENT; only the placement message matters here.
err="$(CLAUDE_PROJECT_DIR="$n" "$CS" --session s1 set-reuse-scan --artifact ".claudehut/tasks/$id/spec.md" 2>&1)"
case "$err" in *"must be under the plane"*) bad "S: artifact under .claudehut/ refused: $err" ;; *) ok "S: an artifact under .claudehut/ passes the placement check" ;; esac
err="$(CLAUDE_PROJECT_DIR="$n" "$CS" --session s1 set-reuse-scan --artifact ".claudehut/../src/Evil.md" 2>&1)"
case "$err" in *"must be under the plane"*) ok "S: a path escaping the plane is refused" ;; *) bad "S: escaping path not refused: $err" ;; esac
err="$(CLAUDE_PROJECT_DIR="$n" "$CS" --session s1 set-reuse-scan --artifact ".claude/claudehut/tasks/$id/spec.md" 2>&1)"
case "$err" in *"must be under the plane"*) ok "S: the legacy path of a .claudehut/ repo is refused (one plane per repo)" ;; *) bad "S: legacy path accepted on a new-layout repo: $err" ;; esac
l="$TMP/s-legacy"; mkdir -p "$l/.claude/claudehut"
out="$(CLAUDE_PROJECT_DIR="$l" "$CS" --session s1 start --route light --slug add-thing 2>&1)"
id="$(ls "$l/.claude/claudehut/tasks" 2>/dev/null | head -1)"
[ -n "$id" ] && [ ! -e "$l/.claudehut" ] && ok "S: a legacy-only repo keeps writing .claude/claudehut/tasks/" || bad "S: legacy start: $out"

echo "== M: claudehut-migrate-plane =="
m="$TMP/m"; mkdir -p "$m/.claude/claudehut/tasks/0001-x" "$m/.claude/rules"; git -C "$m" init -q
printf '{"mode":"mono"}\n' > "$m/.claude/claudehut/topology.json"; printf 't\n' > "$m/.claude/claudehut/tasks/0001-x/task.md"
printf '# Proj\n\nkeep @.claude/rules/x.md\n@.claude/claudehut/MEMORY.md\n@.claude/claudehut/PROJECT.md\n' > "$m/CLAUDE.md"
printf '.claude/\n' > "$m/.gitignore"
snap() { (cd "$1" && find . -path ./.git -prune -o -print | sort; cat CLAUDE.md) | cksum; }
s0="$(snap "$m")"
"$MIG" --dry-run "$m" > "$TMP/dry.out" 2>&1
[ "$(snap "$m")" = "$s0" ] && grep -q 'would move' "$TMP/dry.out" && ok "M: dry-run reports the move and writes nothing" || bad "M: dry-run changed the tree"
"$MIG" --apply "$m" > "$TMP/apply.out" 2>&1; arc=$?
[ "$arc" = 0 ] && [ -f "$m/.claudehut/tasks/0001-x/task.md" ] && [ ! -e "$m/.claude/claudehut" ] && [ -d "$m/.claude/rules" ] \
  && ok "M: apply moves the plane, .claude/rules stays" || bad "M: apply rc=$arc: $(cat "$TMP/apply.out")"
grep -qx '@.claudehut/MEMORY.md' "$m/CLAUDE.md" && grep -qx 'keep @.claude/rules/x.md' "$m/CLAUDE.md" && ! grep -q '@.claude/claudehut/' "$m/CLAUDE.md" \
  && ok "M: only the plane imports in CLAUDE.md are rewritten" || bad "M: CLAUDE.md: $(cat "$m/CLAUDE.md")"
[ "$(cat "$m/.claudehut/.gitignore" 2>/dev/null)" = "*" ] && [ "$(cat "$m/.gitignore")" = ".claude/" ] \
  && ok "M: a local plane stays local (.claudehut/.gitignore '*'), the project .gitignore is untouched" || bad "M: gitignore handling"
s1="$(snap "$m")"; "$MIG" --apply "$m" > "$TMP/re.out" 2>&1
[ "$(snap "$m")" = "$s1" ] && grep -q 'already on' "$TMP/re.out" && ok "M: re-run is a no-op" || bad "M: re-run changed the tree"
b="$TMP/both"; mkdir -p "$b/.claudehut" "$b/.claude/claudehut"
"$MIG" --apply "$b" > "$TMP/both.out" 2>&1 && bad "M: both layouts not refused" \
  || { [ -d "$b/.claude/claudehut" ] && grep -q REFUSED "$TMP/both.out" && ok "M: a repo with both layouts is refused, nothing moved" || bad "M: both-layout handling"; }

echo "== G: no new hard-coded legacy plane paths in runtime code =="
# Every runtime site goes through the resolver; the files listed here handle the legacy layout on purpose.
ALLOW='scripts/lib/plane-path.sh|scripts/kernel/claudehut_kernel/plane.py|bin/claudehut-migrate-plane|bin/claudehut-migrate$|bin/claudehut-init|scripts/lib/hook-common.sh|scripts/register-packs.sh'   # register-packs: self-contained, vendored (07 §1.1)
hits="$(cd "$ROOT" && grep -rlE --exclude-dir=__pycache__ '\.claude/claudehut|"\.claude", *"claudehut"' bin scripts hooks 2>/dev/null | grep -vE "^($ALLOW)" \
  | while read -r f; do grep -nE '\.claude/claudehut|"\.claude", *"claudehut"' "$f" | grep -vE '^[0-9]+: *#|legacy|LEGACY|\.claudehut' | sed "s|^|$f:|"; done)"
[ -z "$hits" ] && ok "G: runtime code reaches the plane only through the resolver" || bad "G: hard-coded plane path(s):
$hits"

echo "PLANE-LAYOUT: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
