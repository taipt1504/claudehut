#!/usr/bin/env bash
# dist-tests.sh — the split distribution (claudehut-kernel dist, docs/v0.20 07 §2-§3, M2b):
#   D1  the build gives two directory marketplaces: public claudehut[-canary] and internal claudehut-internal[-canary]
#   D2  nothing of org-summer reaches the public marketplace; files still naming the internal org are counted in a
#       note (the scrub is a separate user decision)
#   D3  plugin names are unique; the bundle carries only dependencies; dependency ranges accept the prerelease line
#   D4  org-summer runs standalone: its installer imports the vendored extract.py and dry-runs on a consumer
#   D5  only tracked files are shipped (no plane, eval results, local docs, __pycache__)
#   D6  M2 exit 2/2 (when the `claude` CLI is present; CLAUDEHUT_DIST_INSTALL=0 skips): every dir validates, and the
#       bundle installs from the canary directory marketplaces with both dependencies enabled — in a throwaway
#       CLAUDE_CONFIG_DIR, so the user's ~/.claude/plugins is never touched
# Prints "DIST: N passed, M failed"; exit 1 on failure.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
K="$ROOT/bin/claudehut-kernel"
command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || { echo "DIST: 0 passed, 0 failed (no jq/python3)"; exit 0; }
git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 || { echo "DIST: 0 passed, 0 failed (not a git checkout)"; exit 0; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dist-tests.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS+1)); echo "ok - $1"; else FAIL=$((FAIL+1)); echo "FAIL - $1"; fi; }
D="$TMP/dist"; PUB="$D/claudehut-canary"; INT="$D/claudehut-internal-canary"
CH="$PUB/plugins/claudehut"; OS="$INT/plugins/claudehut-org-summer"; BJ="$INT/plugins/claudehut-backend-jvm"
V="$(jq -r .version "$ROOT/.claude-plugin/plugin.json")"

rep="$("$K" dist --out "$D" --channel canary 2>"$TMP/err")"; rc=$?
check "D1: dist --channel canary builds both marketplaces (rc=$rc)" \
  '[ "$rc" = 0 ] && [ -f "$PUB/.claude-plugin/marketplace.json" ] && [ -f "$INT/.claude-plugin/marketplace.json" ] && [ -f "$CH/.claude-plugin/plugin.json" ] && [ -f "$OS/.claude-plugin/plugin.json" ] && [ -f "$BJ/.claude-plugin/plugin.json" ]'
check "D1: marketplace names carry the channel; the internal one allows deps on the public one" \
  '[ "$(jq -r .name "$PUB/.claude-plugin/marketplace.json")" = claudehut-canary ] && [ "$(jq -r ".allowCrossMarketplaceDependenciesOn[0]" "$INT/.claude-plugin/marketplace.json")" = claudehut-canary ]'

check "D2: no org-summer file in the public plugin (skill, manifest, KB snapshot)" \
  '[ ! -e "$CH/skills/summer-kb-setup" ] && [ ! -e "$CH/packs/org-summer" ] && ! grep -rq "summer-kb-setup" "$PUB/.claude-plugin"'
n="$(grep -rlI 'f8a' "$PUB" 2>/dev/null | wc -l | tr -d ' ')"
echo "      note: $n public file(s) still name the internal org (scrub pending a user decision; not shipped anywhere by this test)"

names="$(for f in "$CH" "$OS" "$BJ"; do jq -r .name "$f/.claude-plugin/plugin.json"; done | sort | uniq -d)"
check "D3: plugin names are unique (claudehut, claudehut-org-summer, claudehut-backend-jvm)" '[ -z "$names" ]'
check "D3: the bundle ships only metadata and dependencies (no component dirs)" \
  '[ -z "$(cd "$BJ" && ls -d skills agents hooks bin scripts commands 2>/dev/null)" ] && [ "$(jq ".dependencies|length" "$BJ/.claude-plugin/plugin.json")" = 2 ]'
rng="$(jq -r '.dependencies[0].version' "$OS/.claude-plugin/plugin.json")"
check "D3: the dependency range ($rng) opts into the prerelease line of $V" '[ "$rng" = "~${V%%-*}-0" ]'

F="$TMP/svc"; mkdir -p "$F"; printf "dependencies { implementation 'io.f8a.summer:summer-core:1.0' }\n" >"$F/build.gradle"
imp="$(python3 -B -c "import sys; sys.path.insert(0, sys.argv[1]); import install_summer_kb as k; print(k._extract() is not None)" "$OS/skills/summer-kb-setup/scripts")"
dr="$(python3 -B "$OS/skills/summer-kb-setup/scripts/install_summer_kb.py" "$F" --dry-run 2>&1 | tail -1)"
check "D4: org-summer standalone — vendored extract imports ($imp), installer dry-runs: $dr" '[ "$imp" = True ] && [[ "$dr" == "summer-kb: would be installed"* ]]'
check "D4: its own SessionStart hook runs kb-maintain.sh" 'jq -e ".hooks.SessionStart[0].hooks[0].command | test(\"kb-maintain.sh\")" "$OS/hooks/hooks.json" >/dev/null'

tracked="$(git -C "$ROOT" ls-files)"
extra="$(cd "$CH" && find . -type f ! -path './.claude-plugin/plugin.json' | sed 's#^\./##' | while read -r f; do grep -qxF "$f" <<<"$tracked" || echo "$f"; done)"
check "D5: the public plugin ships tracked files only${extra:+ (extra: $(echo $extra | cut -c1-120))}" '[ -z "$extra" ]'
check "D5: no plane, eval results, local docs or bytecode in any plugin" \
  '[ -z "$(find "$D" \( -name .claudehut -o -name __pycache__ -o -path "*/evals/*" -o -path "*/.claude/docs/*" \) 2>/dev/null)" ]'

if command -v claude >/dev/null 2>&1 && [ "${CLAUDEHUT_DIST_INSTALL:-1}" != 0 ]; then
  hp="${HOME}/.claude/plugins"; hsum() { for f in installed_plugins.json known_marketplaces.json; do cksum "$hp/$f" 2>/dev/null; done; }
  h0="$(hsum)"
  export CLAUDE_CONFIG_DIR="$TMP/cfg"; mkdir -p "$CLAUDE_CONFIG_DIR"
  bad=""
  for p in "$CH" "$OS" "$BJ" "$PUB" "$INT"; do claude plugin validate "$p" >/dev/null 2>&1 || bad="$bad ${p#"$D"/}"; done
  check "D6: every plugin and marketplace dir passes claude plugin validate${bad:+ (failed:$bad)}" '[ -z "$bad" ]'
  claude plugin marketplace add "$PUB" >/dev/null 2>&1; claude plugin marketplace add "$INT" >/dev/null 2>&1
  claude plugin install claudehut-backend-jvm@claudehut-internal-canary >"$TMP/inst" 2>&1; rc=$?
  en="$(claude plugin list 2>/dev/null | awk '/❯/{n=$2} /Status: ✔ enabled/{print n}' | sort | tr '\n' ' ')"
  check "D6 (M2 exit): the bundle installs from the canary marketplaces with both dependencies enabled (rc=$rc; enabled: $en)" \
    '[ "$rc" = 0 ] && [[ "$en" == *"claudehut-backend-jvm@claudehut-internal-canary"* ]] && [[ "$en" == *"claudehut-org-summer@claudehut-internal-canary"* ]] && [[ "$en" == *"claudehut@claudehut-canary"* ]]'
  unset CLAUDE_CONFIG_DIR
  check "D6: the user's ~/.claude/plugins registry is untouched (installed_plugins.json, known_marketplaces.json)" '[ "$(hsum)" = "$h0" ]'
else
  echo "      skip: D6 (no claude CLI or CLAUDEHUT_DIST_INSTALL=0)"
fi

echo "DIST: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
