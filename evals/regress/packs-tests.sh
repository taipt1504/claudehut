#!/usr/bin/env bash
# packs-tests.sh — K10 packs (docs/v0.20 07 §1-§2, M2a): manifests, ownership, detection, and init gated by packs.
#   K1  every packs/<name>/claudehut-pack.json loads and names its own directory
#   K2  every shipped file (bin scripts skills agents hooks templates commands .lsp.json packs/*/rules) belongs to
#       exactly ONE pack, and every literal owned path exists — the precondition of the physical split
#   K3  detection: a Python repo → lang-java-spring off; a Gradle repo → on; a Summer dependency → org-summer on;
#       CLAUDEHUT_PACKS forces a pack and says so
#   K4  claudehut-init on a non-Java repo: no Java rule, no Java identity rule, generic plane templates, the active
#       packs' own rules; --detect reports the packs
#   K5  exit criterion M2: claudehut-init on a copy of THIS repo (bash + Python, no Java) emits no Java rule
#   K6  a repo that stopped being Java: --refresh-rules reports its Java rules as stale and keeps them;
#       --retire-inactive removes them (a learned-pitfalls rule is kept)
#   RG  the pack registry: register-packs.sh writes one entry per manifest into the plane; the kernel reports
#       registered / unregistered / foreign / stale and loads a foreign pack (its vendors.txt reaches vendor-leak)
#   K7  kernel unavailable → the 0.12 behaviour (the Java pack on), never a plane without rules by accident
# Prints "PACKS: N passed, M failed"; exit 1 on failure.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
K="$ROOT/bin/claudehut-kernel"; INIT="$ROOT/bin/claudehut-init"
command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || { echo "PACKS: 0 passed, 0 failed (no jq/python3)"; exit 0; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/packs-tests.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS+1)); echo "ok - $1"; else FAIL=$((FAIL+1)); echo "FAIL - $1"; fi; }
export CLAUDEHUT_HOST_PROBE=0
unset CLAUDEHUT_PACKS
init() { CLAUDE_PLUGIN_ROOT="$ROOT" "$INIT" "$@" --language en --mode mono --git-hooks no >"$TMP/init.out" 2>&1; }
java_rules() { find "$1/.claude/rules" -name '*.md' 2>/dev/null | grep -cE '/(coding|framework|security|testing|performance|observability|architecture)/|/(vocabulary|project-structure)\.md$'; }

out="$("$K" packs --project "$ROOT" --json)"; rc=$?
check "K1: all manifests load (rc=$rc, no errors)" '[ "$rc" = 0 ] && [ "$(jq ".errors|length" <<<"$out")" = 0 ] && [ "$(jq ".packs|length" <<<"$out")" -ge 6 ]'

files="$(cd "$ROOT" && git ls-files bin scripts skills agents hooks templates commands .lsp.json 'packs/*/rules' 2>/dev/null)"
# shellcheck disable=SC2086
own="$(cd "$ROOT" && "$K" packs --owner $files)"
bad="$(jq -r 'to_entries[] | select((.value|length) != 1) | "\(.key) → \(.value)"' <<<"$own")"
check "K2: every shipped file belongs to exactly one pack ($(grep -c . <<<"$files") files)" '[ -z "$bad" ]'
[ -z "$bad" ] || printf '      %s\n' $bad | head -10
missing=""
for m in "$ROOT"/packs/*/claudehut-pack.json; do
  for g in $(jq -r '.owns[] | select(test("[*?]") | not)' "$m"); do [ -e "$ROOT/$g" ] || missing="$missing $g"; done
done
check "K2: every literal owned path exists${missing:+ (missing:$missing)}" '[ -z "$missing" ]'

PY="$TMP/py"; mkdir -p "$PY"; printf 'print(1)\n' >"$PY/app.py"; git -C "$PY" init -q
GR="$TMP/gr"; cp -R "$ROOT/evals/tasks/_fixtures/servlet-jpa/." "$GR/"
SU="$TMP/su"; mkdir -p "$SU"; printf 'dependencies { implementation "io.f8a.summer:summer-core:1.0" }\n' >"$SU/build.gradle"
on() { "$K" packs --project "$1" --json | jq -r --arg p "$2" '.packs[] | select(.pack==$p) | .active'; }
check "K3: a Python repo → lang-java-spring off, lang-python-shell on" '[ "$(on "$PY" lang-java-spring)" = false ] && [ "$(on "$PY" lang-python-shell)" = true ]'
check "K3: a Gradle repo → lang-java-spring on" '[ "$(on "$GR" lang-java-spring)" = true ]'
check "K3: a Summer dependency → org-summer on; none → off" '[ "$(on "$SU" org-summer)" = true ] && [ "$(on "$GR" org-summer)" = false ]'
f="$(CLAUDEHUT_PACKS=+lang-java-spring "$K" packs --project "$PY" --json | jq -r '.packs[]|select(.pack=="lang-java-spring")|"\(.active) \(.why)"')"
check "K3: CLAUDEHUT_PACKS forces a pack and the result says so" '[[ "$f" == "true forced on"* ]]'

init "$PY"
check "K4: init on a Python repo emits no Java rule and no Java identity rule" '[ "$(java_rules "$PY")" = 0 ]'
check "K4: … the generic plane templates (no Java line in PROJECT.md, no Controller in LANGUAGE.md)" \
  '! grep -q "Java" "$PY/.claudehut/PROJECT.md" && grep -q "Stack packs:" "$PY/.claudehut/PROJECT.md" && ! grep -q Controller "$PY/.claudehut/LANGUAGE.md"'
check "K4: … the active packs' rules (python/, shell/) and rules-emitted lists them" \
  '[ -f "$PY/.claude/rules/python/stdlib-tools.md" ] && [ -f "$PY/.claude/rules/shell/strict-mode.md" ] && grep -qx "shell/strict-mode.md" "$PY/.claudehut/rules-emitted.txt"'
check "K4: … no architecture-style note (a Java concept)" '! grep -q "Architecture style" "$TMP/init.out"'
d="$(CLAUDE_PLUGIN_ROOT="$ROOT" "$INIT" "$PY" --detect 2>/dev/null)"
check "K4: --detect reports the active packs" 'jq -e ".packs | index(\"lang-python-shell\") and (index(\"lang-java-spring\") | not)" <<<"$d" >/dev/null'

SELF="$TMP/self"; mkdir -p "$SELF"; (cd "$ROOT" && git archive HEAD) | tar -x -C "$SELF"; rm -rf "$SELF/.claude" "$SELF/.claudehut"; git -C "$SELF" init -q
init "$SELF"
check "K5 (M2 exit): init on a copy of this repo emits no Java rule ($(java_rules "$SELF") found)" '[ "$(java_rules "$SELF")" = 0 ] && [ -f "$SELF/.claude/rules/shell/strict-mode.md" ]'

init "$GR"; n0="$(java_rules "$GR")"
printf '\n## Learned pitfalls\n- keep me\n' >>"$GR/.claude/rules/coding/naming.md"
CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDEHUT_PACKS=-lang-java-spring "$INIT" "$GR" --refresh-rules >"$TMP/rr.out" 2>&1
check "K6: Java repo first ($n0 Java rules); with the pack off --refresh-rules reports them stale and keeps them" \
  '[ "$n0" -gt 10 ] && grep -q "stale: coding/naming.md" "$TMP/rr.out" && [ "$(java_rules "$GR")" = "$n0" ]'
CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDEHUT_PACKS=-lang-java-spring "$INIT" "$GR" --refresh-rules --retire-inactive >"$TMP/rt.out" 2>&1
check "K6: --retire-inactive removes them, except the rule holding learned pitfalls" \
  '[ -f "$GR/.claude/rules/coding/naming.md" ] && [ ! -f "$GR/.claude/rules/coding/immutability.md" ] && grep -q "kept: coding/naming.md" "$TMP/rt.out"'

NK="$TMP/nk"; mkdir -p "$NK"; printf 'print(1)\n' >"$NK/app.py"; git -C "$NK" init -q
CLAUDEHUT_PYTHON=/nonexistent/python3 init "$NK"
check "K7: kernel unavailable → the 0.12 behaviour (Java rules emitted)" '[ "$(java_rules "$NK")" -gt 10 ]'

# ── RG: the pack registry (M5a, 07 §1.1): register-packs.sh (SessionStart) → <plane>/state/packs/<pack>.json ──────
RH="$ROOT/scripts/register-packs.sh"
NP="$TMP/rg-noplane"; mkdir -p "$NP"
out="$(CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$NP" bash "$RH" </dev/null)"; rc=$?
check "RG1: no plane → nothing created, silent, exit 0 (rc=$rc)" '[ "$rc" = 0 ] && [ -z "$out" ] && [ -z "$(ls -A "$NP")" ]'
RP="$TMP/rg"; mkdir -p "$RP/.claudehut"
reg0="$("$K" packs --project "$RP" --json | jq -r '[.packs[].registration] | unique | join(",")')"
check "RG2: before the hook every pack is unregistered (said, not skipped) ($reg0)" '[ "$reg0" = unregistered ]'
out="$(CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$RP" bash "$RH" </dev/null)"; rc=$?
n="$(ls "$RP/.claudehut/state/packs" | wc -l | tr -d ' ')"; nm="$(ls "$ROOT"/packs/*/claudehut-pack.json | wc -l | tr -d ' ')"
check "RG3: one entry per manifest ($n/$nm), silent, exit 0" '[ "$rc" = 0 ] && [ -z "$out" ] && [ "$n" = "$nm" ]'
check "RG4: an entry is {pack, version, root, manifest_hash} with this plugin's root" 'jq -e --arg r "$ROOT" ".pack==\"deliberation\" and .root==\$r and (.version|length>0) and (.manifest_hash|length==64)" "$RP/.claudehut/state/packs/deliberation.json" >/dev/null'
reg1="$("$K" packs --project "$RP" --json | jq -r '[.packs[].registration] | unique | join(",")')"
check "RG5: after the hook every pack is registered ($reg1)" '[ "$reg1" = registered ]'
touch -t 200001010000 "$RP/.claudehut/state/packs/deliberation.json"
CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$RP" bash "$RH" </dev/null
check "RG6: an unchanged entry is not rewritten" '[ "$(find "$RP/.claudehut/state/packs/deliberation.json" -newermt 2001-01-01 | wc -l | tr -d " ")" = 0 ]'
# A foreign pack from another plugin root (the split install), its vendors.txt reaching the vendor-leak sensor.
FR="$TMP/foreign plugin"; mkdir -p "$FR/packs/fakeorg" "$FR/scripts"; cp "$RH" "$FR/scripts/"
printf '{"pack":"fakeorg","version":"0.0.1","kernel":"~0.20","kind":"org","detect":{"always":true},"owns":[]}\n' >"$FR/packs/fakeorg/claudehut-pack.json"
printf 'Acme\n' >"$FR/packs/fakeorg/vendors.txt"
CLAUDE_PLUGIN_ROOT="$FR" CLAUDE_PROJECT_DIR="$RP" bash "$FR/scripts/register-packs.sh" </dev/null
out="$("$K" packs --project "$RP" --json)"
check "RG7: a pack registered from another plugin root loads as foreign and is evaluated (active)" 'jq -e ".packs[]|select(.pack==\"fakeorg\" and .registration==\"foreign\" and .active==true)" <<<"$out" >/dev/null'
mkdir -p "$RP/src/main/java/demo/domain"; printf 'package demo.domain;\n\npublic enum Route {\n  ACME\n}\n' >"$RP/src/main/java/demo/domain/Route.java"
vlo="$(CLAUDE_PROJECT_DIR="$RP" "$ROOT/bin/claudehut-verify" vendor-leak --project "$RP" --json)"
check "RG8: the foreign pack's vendors.txt reaches vendor-leak" 'jq -e "([.vendors[]|select(.name==\"acme\" and .source==\"pack fakeorg\")]|length)==1 and (.findings|length)==1" <<<"$vlo" >/dev/null'
printf ' \n' >>"$FR/packs/fakeorg/claudehut-pack.json"
out="$("$K" packs --project "$RP" --json)"
check "RG9: its manifest changed since it registered → stale, and not loaded" 'jq -e ".packs[]|select(.pack==\"fakeorg\" and .registration==\"stale\" and .active==false)" <<<"$out" >/dev/null'
rm -rf "$FR"
out="$("$K" packs --project "$RP" --json)"
check "RG10: its root is gone → stale" 'jq -e ".packs[]|select(.pack==\"fakeorg\" and .registration==\"stale\")" <<<"$out" >/dev/null'

echo "PACKS: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
