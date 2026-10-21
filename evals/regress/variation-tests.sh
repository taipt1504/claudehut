#!/usr/bin/env bash
# variation-tests.sh — variation-point detectors and the pattern miner (pack lang-java-spring, docs/v0.20 05 §2, M3a)
# against the ground truth frozen BEFORE the detectors were written (evals/fixtures/variation/expected.json):
#   V1  M3 exit: precision >= 0.9, recall >= 0.8 on the labeled fixture; no negative anchor is reported; the miner
#       groups exactly the expected port-selector instances
#   V2  the decision-eval scaffolds (written for another purpose): the SMS provider family and the bank parameter
#   V3  every `# rule:` line carries weight: deleting any one of them lowers the score (or breaks the module)
#   V4  claudehut-index update writes index/variation.json on a Java repo; on a repo the Java pack does not detect
#       it says `applicable:false` with the reason; `claudehut-index variation` tells unknown / not applicable / found
#   V5  deterministic: two runs give byte-identical output
# Prints "VARIATION: N passed, M failed"; exit 1 on failure.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
command -v python3 >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || { echo "VARIATION: 0 passed, 0 failed (no python3/jq)"; exit 0; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/variation-tests.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS+1)); echo "ok - $1"; else FAIL=$((FAIL+1)); echo "FAIL - $1"; fi; }
export CLAUDEHUT_HOST_PROBE=0 CLAUDEHUT_INDEX_NO_SPAWN=1

cat >"$TMP/score.py" <<'PY'
import json, os, subprocess, sys, tempfile
root, idx = sys.argv[1], sys.argv[2]          # idx: the directory holding the variation.py under test
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.join(root, "scripts", "index")); sys.path.insert(0, idx)
import variation
fx = os.path.join(root, "evals/fixtures/variation"); exp = json.load(open(os.path.join(fx, "expected.json")))
def run(repo):
    files = []
    for d, _, fs in os.walk(repo):
        files += [os.path.relpath(os.path.join(d, f), repo) for f in fs if f.endswith(".java")]
    return variation.detect(sorted(files), lambda r: open(os.path.join(repo, r), encoding="utf-8").read())
vps, pats = run(os.path.join(fx, exp["repo"]))
got = {(v["anchor"], v["kind"]) for v in vps if v["kind"] != "extension-point"}
want = {(v["anchor"], v["kind"]) for v in exp["variation_points"]}
tp = len(got & want)
res = {"precision": tp / len(got) if got else 0.0, "recall": tp / len(want), "fp": sorted(map(list, got - want)),
       "fn": sorted(map(list, want - got)), "negatives_hit": sorted({a for a, _ in got} & set(exp["negatives"])),
       "pattern_ok": sorted(i["anchor"] for p in pats for i in p["instances"]) == sorted(exp["patterns"]["port-selector"]),
       "external": {}}
for scaf, e in exp["external"].items():
    d = tempfile.mkdtemp()
    subprocess.run(["bash", os.path.join(root, scaf)], cwd=d, capture_output=True)
    v2, p2 = run(d); g2 = {(v["anchor"], v["kind"]) for v in v2}
    pat = e.get("pattern_includes")
    res["external"][os.path.basename(os.path.dirname(scaf))] = {
        "missing": [m for m in e["must_include"] if (m["anchor"], m["kind"]) not in g2],
        "pattern_ok": (pat is None) or any(i["anchor"] == pat for p in p2 for i in p["instances"])}
ad = json.load(open(os.path.join(fx, "additions", "expected.json")))
av, ap = run(os.path.join(fx, "additions", ad["repo"]))
ag = {(v["anchor"], v["kind"]) for v in av}
res["additions_ok"] = ({a for a, k in ag if k == "extension-point"} == set(ad["extension_points"])
                       and {x for x in ag if x[1] != "extension-point"} == {(v["anchor"], v["kind"]) for v in ad["variation_points"]}
                       and sorted(i["anchor"] for p in ap for i in p["instances"]) == sorted(ad["patterns"]["port-selector"]))
ext_ok = sum(1 for x in res["external"].values() if not x["missing"] and x["pattern_ok"])
f1 = 2 * res["precision"] * res["recall"] / (res["precision"] + res["recall"]) if tp else 0.0
res["score"] = round(f1 + ext_ok + res["pattern_ok"] + res["additions_ok"] - len(res["negatives_hit"]), 6)
print(json.dumps(res, sort_keys=True))
PY
S="$(python3 -B "$TMP/score.py" "$ROOT" "$ROOT/scripts/index")"
p="$(jq -r .precision <<<"$S")"; r="$(jq -r .recall <<<"$S")"
check "V1 (M3 exit): precision $p ≥ 0.9 and recall $r ≥ 0.8 on the frozen fixture (fp $(jq -c .fp <<<"$S"), fn $(jq -c .fn <<<"$S"))" \
  'python3 -c "import sys; sys.exit(not ($p >= 0.9 and $r >= 0.8))"'
check "V1: no negative anchor reported (single impl, test-only impl, Map<String,String>, concrete factory, …)" '[ "$(jq ".negatives_hit|length" <<<"$S")" = 0 ]'
check "V1: the miner groups exactly the expected port-selector instances" '[ "$(jq .pattern_ok <<<"$S")" = true ]'
check "V2: zns scaffold — the SMS provider family (multi-impl + registry) and its pattern" \
  '[ "$(jq ".external[\"zns-follows-provider-pattern\"] | (.missing|length==0) and .pattern_ok" <<<"$S")" = true ]'
check "V2: post-freeze additions — a generic base type is an extension point; a Map-only registry and a factory-only selector are found" '[ "$(jq .additions_ok <<<"$S")" = true ]'
check "V2: bank-export scaffold — the bank parameter of the endpoint is a contract-param VP" \
  '[ "$(jq ".external[\"bank-export-follows-param\"].missing|length" <<<"$S")" = 0 ]'

base="$(jq -r .score <<<"$S")"; dead=""; n=0; brk=0
while IFS=: read -r ln _; do
  n=$((n+1)); mkdir -p "$TMP/m$ln"
  awk -v L="$ln" 'NR != L' "$ROOT/scripts/index/variation.py" >"$TMP/m$ln/variation.py"
  ms="$(python3 -B "$TMP/score.py" "$ROOT" "$TMP/m$ln" 2>/dev/null | jq -r .score 2>/dev/null)"
  if [ -z "$ms" ]; then brk=$((brk+1))
  elif python3 -c "import sys; sys.exit(not ($ms >= $base))"; then dead="$dead $ln"; fi
done < <(grep -n '# rule:[a-z]' "$ROOT/scripts/index/variation.py")
echo "      note: $brk of $n rule deletions break the module (a guard line, not scored semantically)"
check "V3: each of the $n tagged rules carries weight (deleting it lowers the score)${dead:+ — dead at line(s):$dead}" '[ "$n" -ge 8 ] && [ -z "$dead" ] && [ "$brk" -le 3 ]'

IDX="$ROOT/bin/claudehut-index"
J="$TMP/java"; cp -R "$ROOT/evals/fixtures/variation/repo" "$J"; mkdir -p "$J/.claudehut"
git -C "$J" init -q && git -C "$J" add -A && git -C "$J" -c user.email=t@t -c user.name=t commit -qm x
u0="$("$IDX" variation --plane "$J/.claudehut" --json)"
check "V4: before any update, variation answers unknown (not none_found)" '[ "$(jq -r .applicable <<<"$u0")" = null ]'
"$IDX" update --plane "$J/.claudehut" >/dev/null 2>&1
check "V4: update on a Java repo writes index/variation.json (applicable, 11 points, 1 pattern)" \
  '[ "$(jq -c "[.applicable, (.variation_points|length), (.patterns|length)]" "$J/.claudehut/index/variation.json")" = "[true,11,1]" ]'
# A plane indexed BEFORE the detectors existed (every real service): an old tool_version and no variation.json. One
# update must write it (the TOOL_VERSION bump forces the rebuild); a current index merely missing it as well.
jq '.tool_version="0.12.2-idx5"' "$J/.claudehut/index/meta.json" >"$TMP/m" && mv "$TMP/m" "$J/.claudehut/index/meta.json"
rm -f "$J/.claudehut/index/variation.json"
o1="$("$IDX" update --plane "$J/.claudehut" 2>&1)"
check "V4: an index from before M3 (old tool_version, no variation.json) is rebuilt by one update and gets variation.json" \
  '[ -f "$J/.claudehut/index/variation.json" ] && grep -q "extractor changed" <<<"$o1"'
rm -f "$J/.claudehut/index/variation.json"
o2="$("$IDX" update --plane "$J/.claudehut" 2>&1)"
check "V4: a current index missing variation.json is not 'up to date': one update writes it" \
  '[ -f "$J/.claudehut/index/variation.json" ] && ! grep -q "up to date" <<<"$o2"'
PY="$TMP/py"; mkdir -p "$PY/.claudehut"; printf 'print(1)\n' >"$PY/a.py"; git -C "$PY" init -q && git -C "$PY" add -A && git -C "$PY" -c user.email=t@t -c user.name=t commit -qm x
"$IDX" update --plane "$PY/.claudehut" >/dev/null 2>&1
check "V4: on a Python repo variation.json says applicable:false with the reason (never an empty 'none found')" \
  '[ "$(jq -r .applicable "$PY/.claudehut/index/variation.json")" = false ] && jq -r .reason "$PY/.claudehut/index/variation.json" | grep -q "lang-java-spring"'
a="$(python3 -B "$TMP/score.py" "$ROOT" "$ROOT/scripts/index")"; b="$(python3 -B "$TMP/score.py" "$ROOT" "$ROOT/scripts/index")"
check "V5: deterministic (two runs byte-identical)" '[ "$a" = "$b" ]'
check "V5: no __pycache__ written into the plugin" '[ -z "$(find "$ROOT/scripts/index" -name __pycache__)" ]'

echo "VARIATION: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
