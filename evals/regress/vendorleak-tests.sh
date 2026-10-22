#!/usr/bin/env bash
# vendorleak-tests.sh — the vendor-leak sensor (M4; docs/v0.20 06 §2, appendix a2 R3), `claudehut-verify vendor-leak`:
#   V1-V4  frozen fixture (evals/fixtures/vendor-leak, ground truth written before the code): precision and recall 1.0,
#          no finding in a negative file (adapters, a Strategy family's keys, concern nouns, YAML, tests), no stop word
#          or concern noun taken for a vendor
#   V5-V6  the variation fixture (written for the detectors, not for this sensor): vendors derived, zero findings
#   V7-V9  no index → only the owner's list, said as families=unknown; no vendor known → silent, exit 0; a path
#          argument limits the scan
# Self-contained temp copies, no network. Prints "VENDORLEAK: N passed, M failed"; exit 1 on failure.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
command -v python3 >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || { echo "VENDORLEAK: 0 passed, 0 failed (no python3/jq)"; exit 0; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/vendorleak tests.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS+1)); echo "ok - $1"; else FAIL=$((FAIL+1)); echo "FAIL - $1"; fi; }
export CLAUDEHUT_HOST_PROBE=0 CLAUDEHUT_INDEX_NO_SPAWN=1
unset CLAUDEHUT_PACKS

repo() { # $1 fixture repo dir  $2 name  $3 index yes|no → a git copy with a plane
  local p="$TMP/$2"
  cp -R "$1" "$p"; mkdir -p "$p/.claudehut"
  git -C "$p" init -q && git -C "$p" add -A && git -C "$p" -c user.email=t@t -c user.name=t commit -qm i
  [ "$3" = no ] || CLAUDE_PROJECT_DIR="$p" "$ROOT/bin/claudehut-index" update --plane "$p/.claudehut" >/dev/null 2>&1
  printf '%s' "$p"
}
vl() { local p="$1"; shift; CLAUDE_PROJECT_DIR="$p" "$ROOT/bin/claudehut-verify" vendor-leak --project "$p" --json "$@"; }

FX="$ROOT/evals/fixtures/vendor-leak"
P="$(repo "$FX/repo" fx yes)"
vl "$P" >"$TMP/fx.json"; rc=$?
python3 - "$FX/expected.json" "$TMP/fx.json" >"$TMP/score.json" <<'PY'
import json, sys
exp, got = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
g = {(f["file"], f["kind"], f["vendor"]) for f in got["findings"]}
w = {(f["file"], f["kind"], f["vendor"]) for f in exp["findings"]}
tp = len(g & w)
print(json.dumps({"precision": tp / len(g) if g else 0.0, "recall": tp / len(w),
                  "negatives_hit": sorted({f for f, _, _ in g} & set(exp["negatives"])),
                  "vendors_ok": sorted(v["name"] for v in got["vendors"]) == sorted(exp["vendors"]),
                  "not_vendors_hit": sorted(set(exp["not_vendors"]) & {v["name"] for v in got["vendors"]})}))
PY
check "V1: frozen fixture — exit 1 with findings (rc=$rc), precision 1.0 ($(jq .precision "$TMP/score.json"))" '[ "$rc" = 1 ] && jq -e ".precision == 1" "$TMP/score.json" >/dev/null'
check "V2: recall 1.0 ($(jq .recall "$TMP/score.json"))" 'jq -e ".recall == 1" "$TMP/score.json" >/dev/null'
check "V3: no finding in a negative file" 'jq -e ".negatives_hit == []" "$TMP/score.json" >/dev/null'
check "V4: vendors = owner list + derived variants; no stop word or concern noun among them" 'jq -e ".vendors_ok and .not_vendors_hit == []" "$TMP/score.json" >/dev/null'

P2="$(repo "$ROOT/evals/fixtures/variation/repo" var yes)"
vl "$P2" >"$TMP/var.json"; rc=$?
check "V5: variation fixture — 7 vendors derived from 3 external-looking families" '[ "$(jq -c "[.vendors[].name]" "$TMP/var.json")" = "[\"apns\",\"cmc\",\"fcm\",\"fpt\",\"iris\",\"tcb\",\"vcb\"]" ]'
check "V6: variation fixture — zero findings, exit 0 (rc=$rc)" '[ "$rc" = 0 ] && jq -e ".findings == []" "$TMP/var.json" >/dev/null'

P3="$(repo "$FX/repo" noidx no)"
vl "$P3" >"$TMP/noidx.json"
check "V7: no index → families unknown, only the owner's vendors.txt (napas: 2 findings)" 'jq -e ".families == \"unknown\" and ([.vendors[].name] == [\"napas\"]) and (.findings|length) == 2" "$TMP/noidx.json" >/dev/null'
rm -f "$P3/.claudehut/vendors.txt"
vl "$P3" >"$TMP/none.json"; rc=$?
check "V8: no vendor known → no finding, exit 0 (rc=$rc)" '[ "$rc" = 0 ] && jq -e ".findings == [] and .vendors == []" "$TMP/none.json" >/dev/null'
vl "$P" src/main/java/demo/notify/domain/SmsLog.java >"$TMP/one.json"
check "V9: a path argument limits the scan (SmsLog.java: column + field)" 'jq -e "[.findings[].kind] | sort == [\"column\",\"field\"]" "$TMP/one.json" >/dev/null'

# V10-V12 were added AFTER the code to kill three surviving mutants (not part of the frozen precision/recall truth).
J="$P/src/main/java/demo"; mkdir -p "$J/payment/napas" "$J/notify/app"
printf 'package demo.payment.napas;\n\npublic class NapasClient {\n  private String napasUrl;\n}\n' >"$J/payment/napas/NapasClient.java"
printf 'package demo.notify.app;\n\npublic class NotifyService {\n  private String fptFallback;\n}\n' >"$J/notify/app/NotifyService.java"
printf 'CREATE TABLE fpt_callback (\n  id BIGINT,\n  payload TEXT\n);\n' >"$P/src/main/resources/db/migration/V3__cb.sql"
vl "$P" src/main/java/demo/payment/napas src/main/java/demo/notify/app src/main/resources/db/migration/V3__cb.sql >"$TMP/add.json"
check "V10: a vendor package segment outside domain/model/entity/core is the adapter's place (no package finding)" '! jq -e ".findings[]|select(.kind==\"package\")" "$TMP/add.json" >/dev/null'
check "V11: fields are judged only in entity / @ConfigurationProperties classes (NotifyService.fptFallback is not)" '! jq -e ".findings[]|select(.file|endswith(\"NotifyService.java\"))" "$TMP/add.json" >/dev/null'
check "V12: CREATE TABLE fpt_callback is a table finding" '[ "$(jq -c "[.findings[]|select(.file|endswith(\"V3__cb.sql\"))|.kind]" "$TMP/add.json")" = "[\"table\"]" ]'

# V13 added after the code (advisor review): an owner-listed vendor's own adapter package is not neutral either.
printf 'package demo.payment.napas;\n\nenum NapasStatus {\n  NAPAS_OK\n}\n' >"$J/payment/napas/NapasStatus.java"
vl "$P" src/main/java/demo/payment/napas >"$TMP/adp.json"; rc=$?
check "V13: an enum inside the vendor-named adapter package (demo.payment.napas) is not a finding (rc=$rc)" '[ "$rc" = 0 ] && jq -e ".findings == []" "$TMP/adp.json" >/dev/null'

echo "VENDORLEAK: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
