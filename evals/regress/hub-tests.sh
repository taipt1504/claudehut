#!/usr/bin/env bash
# hub-tests.sh — regression pins for the microservice hub: scripts/index/hub.py + the hub commands of
# claudehut-index (hub-sync, hub-scan, update --hub-sync, svc <other>, find --svc, links) and the client-target
# resolution of extract.py (07-index-memory.md §4.3, §5; AC-8, AC-9, AC-10). Deterministic, no Claude, no network.
#
#   1. fixture (AC-8)   3 generated repos from evals/fixtures/hub: a-ms, b-ms indexed (plane), c-ms hub-scanned (no
#                       plane). Full sorted edge + unresolved set == expected-links.json: a→b http high (with the
#                       resolved client class as evidence), a→external host, a→c kafka high (SpEL constant listener +
#                       reactor-kafka receiver via a props field; the receiver factory emits nothing),
#                       a→java-common-ms lib, b→c shared-db medium (c owns the migration); prefix-only producer,
#                       orphan consumer and an unknown client env are `unresolved`; r2dbc/redis/SERVER_HOST/
#                       LOG_LEVEL_*SECURITY and a self-produced topic never become edges
#   2. evidence         every evidence path passes test -f through services.json; re-sync is byte-identical
#   3. read-only        hub-scan leaves every mtime of c-ms (incl. .git) unchanged and creates no .claude/ or
#                       .understand-anything/; a service repo's own UA graph keeps its checksum (AC-10)
#   4. UA schema        knowledge-graph.json passes understand-anything's own validateGraph with 0 issues and no
#                       dropped node/edge, sanitizeGraph is a no-op (skipped when node or the UA core dist is absent);
#                       dashboard HTTP 200 on /knowledge-graph.json serving this graph (HUB_NO_DASHBOARD=1 skips)
#   5. aliases          pristine aliases.json carries _suggested; a user edit is never rewritten and its alias wins
#   6. CLI              links filters, svc <other> ≤2.5 KB + stale banner (hub-scan repo → hub-scan --repo), find --svc, update --hub-sync via
#                       topology.hub, HUB.md ≤3 KB even with 200 edges
#   7. ewallet (report) read-only clones of va-ms, payment-orchestrator-ms, core-ledger-ms, payment-gateway-ms (plane)
#                       + java-common-ms (hub-scan): AC-9 checks and the edge list (HUB_NO_EWALLET=1 skips)
#   8. init-driven      claudehut-init with the inner hub dir (--hub, CLAUDEHUT_HUB) → one hub; rootProject.name ≠ repo
#                       dir: evidence by repo dir, env joins the dir name, svc/links/find accept it; a yml-only
#                       consumer topic joins (medium); cdc URL / shared group make no edge; hint-explore speaks vi
#
# Run: evals/regress/hub-tests.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CLI="$ROOT/bin/claudehut-index"
FX="$ROOT/evals/fixtures/hub"
EWS="${HUB_EWALLET_WS:-/Users/taiphan/Documents/Projects/ewallet-workspace}"
UA="${HUB_UA_ROOT:-$(ls -d "$HOME"/.claude/plugins/cache/understand-anything/understand-anything/* 2>/dev/null | sort -V | tail -1)}"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
unset CLAUDE_PROJECT_DIR CLAUDEHUT_HUB CLAUDEHUT_SESSION_ID CLAUDEHUT_INDEX_TEST_FAIL
export CLAUDEHUT_INDEX_NO_SPAWN=1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; }
chk() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

W="$(mktemp -d)"; DASH_PID=""
trap '[ -n "$DASH_PID" ] && kill "$DASH_PID" 2>/dev/null; rm -rf "$W"' EXIT
W="$(cd "$W" && pwd -P)"
export TMPDIR="$W/tmp" CLAUDE_PLUGIN_DATA="$W/plugin-data"; mkdir -p "$TMPDIR"

repo() { cp -R "$FX/$1" "$W/$1"; git -C "$W/$1" init -q -b main; git -C "$W/$1" config commit.gpgsign false
         git -C "$W/$1" add -A; git -C "$W/$1" commit -qm base --no-verify; }
ix() { local d="$1"; shift; OUT="$(cd "$d" && "$CLI" "$@" 2>"$W/stderr")"; RC=$?; }
sha() { python3 -c 'import hashlib,sys; print(hashlib.sha1(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }
snap() { python3 - "$1" <<'PY'
import os, sys
root = sys.argv[1]
for d, ds, fs in os.walk(root):
    for n in sorted(ds + fs):
        p = os.path.join(d, n)
        print(os.lstat(p).st_mtime_ns, os.path.relpath(p, root))
PY
}
H="$W/hubrepo/.claude/claudehut/hub"

# ---------------------------------------------------------------- 1. fixture ------------------------------------
echo "== 1. fixture: 3 repos → exact edges (AC-8) =="
for r in a-ms b-ms c-ms; do repo "$r"; done
mkdir -p "$W/a-ms/.claude/claudehut" "$W/b-ms/.claude/claudehut" "$W/a-ms/.understand-anything" "$W/hubrepo"
printf '{"nodes":[],"edges":[]}\n' > "$W/a-ms/.understand-anything/knowledge-graph.json"
ua_before="$(sha "$W/a-ms/.understand-anything/knowledge-graph.json")"
git -C "$W/hubrepo" init -q -b main
# the skeleton claudehut-init writes (hub_setup): must stay compatible — a pristine aliases.json, a flat services.json
mkdir -p "$H"; printf '{"env":{},"topic_owner":{},"db_owner":{}}\n' > "$H/aliases.json"
printf '{"a-ms":{"path":"../a-ms","has_plane":true}}\n' > "$H/services.json"
ix "$W/a-ms" update; ix "$W/b-ms" update
c_before="$(snap "$W/c-ms")"
ix "$W/hubrepo" hub-sync --hub . --repo ../a-ms --repo ../b-ms
chk "hub-sync registers 2 planes" '[[ "$OUT" == "hub: synced 2 services"* ]]'
ix "$W/hubrepo" hub-scan --hub . --repo "$W/c-ms"
chk "hub-scan adds c-ms (no plane): 3 services, 5 edges, 3 unresolved" \
  '[[ "$OUT" == "hub: synced 3 services, 5 edges (http 2, kafka 1, lib 1, db 1), 3 unresolved"* ]]'
chk "services.json: c-ms has_plane=false, a-ms/b-ms true, paths relative to the hub root" \
  '[ "$(jq -c "[.\"a-ms\".has_plane, .\"b-ms\".has_plane, .\"c-ms\".has_plane, .\"c-ms\".path]" "$H/services.json")" = "[true,true,false,\"../c-ms\"]" ]'
GOT="$(jq -S '{edges: .edges, unresolved: .unresolved}' "$H/service-links.json")"; WANT="$(jq -S . "$FX/expected-links.json")"
chk "edge + unresolved set == expected-links.json (exact)" '[ "$GOT" = "$WANT" ]'
[ "$GOT" = "$WANT" ] || diff <(printf '%s\n' "$WANT") <(printf '%s\n' "$GOT") | head -20
chk "reactor-kafka (hub-scan): XReactiveConsumer → high consume of x.v1 via its props field's yml key; the receiver factory (param only) emits no listener" \
  'jq -e "any(.kafka.consumes[]; .topic==\"x.v1\" and .at==[\"src/main/java/com/acme/c/kafka/XReactiveConsumer.java:15\",\"src/main/resources/application.yml:14\"])" "$H/links/c-ms.json" >/dev/null && jq -e "[.components[] | select(.kind==\"listener\" and (.file|test(\"KafkaConfigUtil\")))] | length == 0" "$H/links/c-ms.json" >/dev/null'
chk "no edge from r2dbc/redis/SERVER_HOST/LOG_LEVEL/self-topic/offset topics" \
  '! jq -e "[.edges[] | .via] | any(test(\"R2DBC|REDIS|SERVER_HOST|LOG_LEVEL|b.internal|offsets|schema.history\"))" "$H/service-links.json" >/dev/null'
chk "HUB.md ≤3072 B, lists 3 services and the 5 edges" \
  '[ "$(wc -c < "$H/HUB.md")" -le 3072 ] && grep -q "c-ms \`../c-ms\`.*(hub-scan)" "$H/HUB.md" && [ "$(grep -c "^- .* → " "$H/HUB.md")" = 5 ]'
chk "hub.json created as {schema:1} (language is init's)" '[ "$(jq -c . "$H/hub.json")" = "{\"schema\":1}" ]'

# ---------------------------------------------------------------- 2. evidence + determinism -----------------------
echo "== 2. evidence + determinism =="
nbad=0
while read -r e; do
  s="${e%%/*}"; rest="${e#*/}"; f="${rest%:*}"; ln="${rest##*:}"
  p="$(jq -r --arg s "$s" '.[$s].path // empty' "$H/services.json")"
  [ -n "$p" ] || continue  # java-common-ms: a lib owner not registered in this fixture
  if [ ! -f "$W/hubrepo/$p/$f" ] || [ "$(wc -l < "$W/hubrepo/$p/$f")" -lt "$ln" ]; then nbad=$((nbad+1)); echo "    missing: $e"; fi
done < <(jq -r '.edges[].evidence[], .unresolved[].at' "$H/service-links.json")
chk "every evidence/at path exists (test -f) with that line" '[ "$nbad" = 0 ]'
b1="$(sha "$H/service-links.json") $(sha "$H/HUB.md") $(sha "$H/.understand-anything/knowledge-graph.json") $(sha "$H/aliases.json") $(sha "$H/services.json")"
sleep 1; ix "$W/hubrepo" hub-sync
b2="$(sha "$H/service-links.json") $(sha "$H/HUB.md") $(sha "$H/.understand-anything/knowledge-graph.json") $(sha "$H/aliases.json") $(sha "$H/services.json")"
chk "re-sync: service-links, HUB.md, graph, aliases, services.json byte-identical" '[ "$b1" = "$b2" ]'
chk "hub .gitignore keeps links/, service-links.json, .understand-anything/ out of git" \
  'grep -qx "links/" "$H/.gitignore" && grep -qx "service-links.json" "$H/.gitignore" && grep -qx ".understand-anything/" "$H/.gitignore"'

# ---------------------------------------------------------------- 3. read-only -----------------------------------
echo "== 3. read-only service repos =="
chk "hub-scan/hub-sync left every mtime of c-ms (incl. .git) unchanged" '[ "$c_before" = "$(snap "$W/c-ms")" ]'
chk "c-ms has no .claude/ and no .understand-anything/" '[ ! -e "$W/c-ms/.claude" ] && [ ! -e "$W/c-ms/.understand-anything" ]'
chk "a-ms own UA graph checksum unchanged" '[ "$ua_before" = "$(sha "$W/a-ms/.understand-anything/knowledge-graph.json")" ]'
chk "graph written only under the hub dir" '[ -f "$H/.understand-anything/knowledge-graph.json" ] && [ ! -e "$W/hubrepo/.understand-anything" ]'

# ---------------------------------------------------------------- 4. UA schema -------------------------------------
echo "== 4. understand-anything schema (AC-10) =="
G="$H/.understand-anything/knowledge-graph.json"
if command -v node >/dev/null 2>&1 && [ -f "$UA/packages/core/dist/schema.js" ]; then
  VR="$(cd "$UA/packages/core" && node --input-type=module -e '
import { validateGraph, sanitizeGraph } from "./dist/schema.js";
import fs from "fs";
const g = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const r = validateGraph(g);
console.log(JSON.stringify({success: r.success, issues: r.issues.length, fatal: r.fatal ?? null,
  nodes: g.nodes.length === (r.data?.nodes.length ?? -1), edges: g.edges.length === (r.data?.edges.length ?? -1),
  layers: g.layers.length === (r.data?.layers.length ?? -1),
  sanitizeNoop: JSON.stringify(sanitizeGraph(g)) === JSON.stringify(g)}));' "$G" 2>&1)"
  chk "UA validateGraph: success, 0 issues, no node/edge/layer dropped, sanitizeGraph no-op ($UA)" \
    '[ "$VR" = "{\"success\":true,\"issues\":0,\"fatal\":null,\"nodes\":true,\"edges\":true,\"layers\":true,\"sanitizeNoop\":true}" ]'
  [ "$VR" = '{"success":true,"issues":0,"fatal":null,"nodes":true,"edges":true,"layers":true,"sanitizeNoop":true}' ] || echo "    $VR"
else
  echo "  skip - UA validator (node or $UA/packages/core/dist/schema.js absent)"
fi
chk "graph nodes: service:a-ms/b-ms/c-ms, topic:x.v1, table:shared_db, module:summer, resource:external:*" \
  '[ "$(jq -c "[.nodes[].id]" "$G")" = "[\"module:summer\",\"resource:external:api.partner.example.com\",\"service:a-ms\",\"service:b-ms\",\"service:c-ms\",\"table:shared_db\",\"topic:x.v1\"]" ]'
chk "graph edge weights: high=1, medium=0.6" \
  'jq -e "([.edges[] | select(.type==\"reads_from\") | .weight] | unique) == [0.6] and ([.edges[] | select(.type==\"calls\") | .weight] | unique) == [1]" "$G" >/dev/null'
DASH="$UA/packages/dashboard"
if [ "${HUB_NO_DASHBOARD:-0}" != 1 ] && command -v node >/dev/null 2>&1 && [ -x "$DASH/node_modules/.bin/vite" ]; then
  TOK="hubtest$$"; PORT=$((20000 + $$ % 20000))
  (cd "$DASH" && GRAPH_DIR="$H" UNDERSTAND_ACCESS_TOKEN="$TOK" exec "$DASH/node_modules/.bin/vite" --host 127.0.0.1 --port "$PORT" --strictPort \
     >"$W/dash.log" 2>&1) & DASH_PID=$!
  code=000
  for _ in $(seq 1 40); do
    code="$(curl -s -o "$W/dash.json" -w '%{http_code}' "http://127.0.0.1:$PORT/knowledge-graph.json?token=$TOK" 2>/dev/null)"
    [ "$code" = 200 ] && break; sleep 1
  done
  chk "dashboard: GET /knowledge-graph.json?token= → 200 serving the hub graph (GRAPH_DIR=<hub dir>)" \
    '[ "$code" = 200 ] && [ "$(jq -c "[.nodes[].id]" "$W/dash.json")" = "$(jq -c "[.nodes[].id]" "$G")" ]'
  code2="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/" 2>/dev/null)"
  chk "dashboard: GET / → 200" '[ "$code2" = 200 ]'
  kill "$DASH_PID" 2>/dev/null; wait "$DASH_PID" 2>/dev/null; DASH_PID=""
else
  echo "  skip - dashboard (HUB_NO_DASHBOARD=1, node or $DASH/node_modules absent)"
fi

# ---------------------------------------------------------------- 5. aliases -------------------------------------
echo "== 5. aliases.json =="
chk "pristine aliases.json: empty user maps + _suggested db_owner shared_db=c-ms" \
  '[ "$(jq -c "[.env, .topic_owner, .db_owner, .lib_owner, ._suggested.db_owner]" "$H/aliases.json")" = "[{},{},{},{},{\"shared_db\":\"c-ms\"}]" ]'
jq '.env.MYSTERY_URL = "c-ms"' "$H/aliases.json" > "$W/al.json" && cp "$W/al.json" "$H/aliases.json"
al_before="$(sha "$H/aliases.json")"
ix "$W/hubrepo" hub-sync
chk "user-edited aliases.json is never rewritten" '[ "$al_before" = "$(sha "$H/aliases.json")" ]'
chk "suggestions go to aliases.suggested.json instead" '[ -f "$H/aliases.suggested.json" ]'
chk "alias wins: a-ms → c-ms http via MYSTERY_URL high; MYSTERY_URL no longer unresolved" \
  'jq -e "any(.edges[]; .from==\"a-ms\" and .to==\"c-ms\" and .type==\"http\" and .via==\"MYSTERY_URL\" and .confidence==\"high\") and ([.unresolved[] | select(.env==\"MYSTERY_URL\")] | length == 0)" "$H/service-links.json" >/dev/null'

# ---------------------------------------------------------------- 6. CLI ------------------------------------------
echo "== 6. CLI =="
printf '{"schema":1,"mode":"microservice","service":"a-ms","hub":"../hubrepo","shared":false,"git_hooks":false}\n' \
  > "$W/a-ms/.claude/claudehut/topology.json"
ix "$W/a-ms" links --type kafka
chk "links --type kafka from a service (topology.hub) → one a-ms → c-ms line" \
  '[ "$(printf "%s\n" "$OUT" | grep -c "^a-ms → c-ms kafka via x.v1 (high)")" = 1 ] && [[ "$OUT" == *"1 edge(s)"* ]]'
ix "$W/a-ms" links --service b-ms --json
chk "links --service b-ms --json → 2 edges (a→b http, b→c db)" '[ "$(jq ".edges | length" <<<"$OUT")" = 2 ]'
ix "$W/a-ms" svc b-ms
chk "svc b-ms (another service) ≤2500 B: endpoints, used-by a-ms, DB" \
  '[ "$(printf "%s\n" "$OUT" | wc -c)" -le 2500 ] && [[ "$OUT" == *"repo: $W/b-ms (paths below"* ]] && [[ "$OUT" == *"GET /api/v1/orders/{id}"* ]] && [[ "$OUT" == *"Used by: a-ms(http high)"* ]] && [[ "$OUT" == *"DB: shared_db"* ]]'
ix "$W/a-ms" svc nosuch-ms
chk "svc <unknown> → one line naming the known services" '[[ "$OUT" == "index: service nosuch-ms is not in the hub — known: a-ms, b-ms, c-ms" ]]'
ix "$W/a-ms" find Order --svc b-ms
chk "find --svc b-ms → rows with absolute paths into b-ms" '[[ "$OUT" == *"controller com.acme.b.web.OrderController $W/b-ms/src/main/java/com/acme/b/web/OrderController.java:"* ]]'
printf '// touch\n' >> "$W/b-ms/src/main/java/com/acme/b/web/OrderController.java"; git -C "$W/b-ms" commit -qam next --no-verify
ix "$W/a-ms" svc b-ms
chk "svc b-ms after a new commit → stale banner, no wait" '[[ "$(printf "%s\n" "$OUT" | head -1)" == *"[stale: 1 commit(s) behind"* ]]'
printf 'x\n' > "$W/c-ms/NOTES.txt"; git -C "$W/c-ms" add -A; git -C "$W/c-ms" commit -qm next --no-verify
ix "$W/a-ms" svc c-ms
chk "svc c-ms (a hub-scan repo) after a new commit → stale banner suggests hub-scan --repo <its path>" \
  '[[ "$(printf "%s\n" "$OUT" | head -1)" == *"[stale: 1 commit(s) behind — refresh: hub-scan --repo $W/c-ms]" ]]'
chk "update --hub-sync (hub from CLAUDEHUT_HUB) refreshes the hub's commit for b-ms" \
  'CLAUDEHUT_HUB="$W/hubrepo" "$CLI" update --hub-sync --plane "$W/b-ms/.claude/claudehut" >/dev/null; [ "$(jq -r ".\"b-ms\".indexed_commit" "$H/services.json")" = "$(git -C "$W/b-ms" rev-parse HEAD)" ]'
before_a="$(sha "$H/links/a-ms.json")"
printf 'package com.acme.a.kafka;\n\nimport org.springframework.kafka.annotation.KafkaListener;\nimport org.springframework.stereotype.Component;\n\n@Component\npublic class Extra {\n  @KafkaListener(topics = "b.internal.v1")\n  public void on(String v) {}\n}\n' \
  > "$W/a-ms/src/main/java/com/acme/a/kafka/Extra.java"; git -C "$W/a-ms" add -A; git -C "$W/a-ms" commit -qm extra --no-verify
ix "$W/a-ms" update --hub-sync
chk "update --hub-sync via topology.hub: new listener → b-ms → a-ms kafka b.internal.v1 high" \
  '[ "$before_a" != "$(sha "$H/links/a-ms.json")" ] && jq -e "any(.edges[]; .from==\"b-ms\" and .to==\"a-ms\" and .via==\"b.internal.v1\" and .confidence==\"high\")" "$H/service-links.json" >/dev/null'
before_a="$(sha "$H/links/a-ms.json")"
sed -i.bak 's/"b.internal.v1"/"c.internal.v1"/' "$W/a-ms/src/main/java/com/acme/a/kafka/Extra.java"; rm -f "$W/a-ms/src/main/java/com/acme/a/kafka/Extra.java.bak"
git -C "$W/a-ms" commit -qam extra2 --no-verify
ix "$W/a-ms" update
chk "plain update on a microservice plane ends in hub-sync (07 §7: git hook / inject-phase path)" \
  '[ "$before_a" != "$(sha "$H/links/a-ms.json")" ] && [ "$(jq -r ".\"a-ms\".indexed_commit" "$H/services.json")" = "$(git -C "$W/a-ms" rev-parse HEAD)" ]'
ix "$W/hubrepo" brief order
chk "brief at the hub (no index of its own) ranks every service's components, absolute paths (AC-12)" \
  '[[ "$OUT" == "Hub "*"3 services"* ]] && [[ "$OUT" == *"- [b-ms] controller com.acme.b.web.OrderController $W/b-ms/"* ]] && [ "$(printf "%s\n" "$OUT" | wc -c)" -le 3000 ]'
ix "$W/hubrepo" brief --json --budget 600
chk "brief --json at the hub keeps the shared contract (sections = markdown lines) and the budget" \
  '[ "$(jq -r "[.budget, (.bytes <= 600), (.sections[0].name), ((.markdown | split(\"\\n\") | length) == ([.sections[].lines[]] | length))] | join(\",\")" <<<"$OUT")" = "600,true,banner,true" ]'
ix "$W/c-ms" links
chk "links in a repo with no plane and no hub → hub not configured" '[ "$OUT" = "n/a — hub not configured" ]'
HB="$(python3 -B - "$ROOT/scripts/index" "$H" <<'PY'
import sys; sys.path.insert(0, sys.argv[1]); import hub
edges = [{"from": "svc-%03d-ms" % i, "to": "core-%03d-ms" % i, "type": "http", "via": "CORE_%03d_SERVICE_URL" % i,
          "confidence": "high", "evidence": []} for i in range(200)]
svcs = {"svc-%03d-ms" % i: {"path": "../svc-%03d-ms" % i, "indexed_commit": "0" * 40, "has_plane": True} for i in range(40)}
print(len(hub.hub_md(sys.argv[2], svcs, edges, [{}] * 9).encode()))
PY
)"
chk "HUB.md stays ≤3072 B with 40 services and 200 edges ($HB B)" '[ "$HB" -le 3072 ]'

# ---------------------------------------------------------------- 7. ewallet --------------------------------------
echo "== 7. ewallet services (read-only clones, report) =="
if [ "${HUB_NO_EWALLET:-0}" = 1 ] || [ ! -d "$EWS/va-ms/.git" ]; then
  echo "  skip - ewallet workspace absent or HUB_NO_EWALLET=1"
else
  E="$W/ew"; mkdir -p "$E/ewallet-knowledge"; git -C "$E/ewallet-knowledge" init -q -b main
  src_idx="$(for r in va-ms payment-orchestrator-ms core-ledger-ms payment-gateway-ms java-common-ms; do stat -f %m "$EWS/$r/.git/index" 2>/dev/null || stat -c %Y "$EWS/$r/.git/index"; done)"
  for r in va-ms payment-orchestrator-ms core-ledger-ms payment-gateway-ms java-common-ms; do
    git clone -q --no-hardlinks "$EWS/$r" "$E/$r" 2>/dev/null
  done
  for r in va-ms payment-orchestrator-ms core-ledger-ms payment-gateway-ms; do
    mkdir -p "$E/$r/.claude/claudehut"; "$CLI" update --plane "$E/$r/.claude/claudehut" >/dev/null
  done
  ix "$E/ewallet-knowledge" hub-sync --hub . --repo ../va-ms,../payment-orchestrator-ms,../core-ledger-ms,../payment-gateway-ms
  jc_before="$(snap "$E/java-common-ms")"
  ix "$E/ewallet-knowledge" hub-scan --hub . --repo ../java-common-ms; echo "  $OUT"
  EH="$E/ewallet-knowledge/.claude/claudehut/hub"
  chk "AC-9: every lib edge goes to java-common-ms" 'jq -e "[.edges[] | select(.type==\"lib\") | .to] | length > 0 and all(. == \"java-common-ms\")" "$EH/service-links.json" >/dev/null'
  chk "AC-9: LEDGER_SERVICE_URL → core-ledger-ms medium" \
    'jq -e "any(.edges[]; .from==\"payment-orchestrator-ms\" and .to==\"core-ledger-ms\" and .via==\"LEDGER_SERVICE_URL\" and .confidence==\"medium\")" "$EH/service-links.json" >/dev/null'
  chk "pg client targets resolved: PGMS_CORE_LEDGER_BASE_URL → core-ledger-ms high with the config class as evidence" \
    'jq -e "any(.edges[]; .from==\"payment-gateway-ms\" and .to==\"core-ledger-ms\" and .confidence==\"high\" and any(.evidence[]; test(\"CoreLedgerWebClientConfig.java\")))" "$EH/service-links.json" >/dev/null'
  nbad=0
  while read -r e; do
    s="${e%%/*}"; rest="${e#*/}"; f="${rest%:*}"
    [ -f "$E/$s/$f" ] || { nbad=$((nbad+1)); echo "    missing: $e"; }
  done < <(jq -r '.edges[] | select(.type=="http" or .type=="kafka") | .evidence[]' "$EH/service-links.json")
  chk "AC-9: every http/kafka evidence file exists" '[ "$nbad" = 0 ]'
  chk "HUB.md ≤3072 B" '[ "$(wc -c < "$EH/HUB.md")" -le 3072 ]'
  if command -v node >/dev/null 2>&1 && [ -f "$UA/packages/core/dist/schema.js" ]; then
    n="$(cd "$UA/packages/core" && node --input-type=module -e 'import { validateGraph } from "./dist/schema.js"; import fs from "fs";
      const r = validateGraph(JSON.parse(fs.readFileSync(process.argv[1], "utf8"))); console.log(r.success ? r.issues.length : -1);' "$EH/.understand-anything/knowledge-graph.json")"
    chk "ewallet graph: UA validateGraph 0 issues" '[ "$n" = 0 ]'
  fi
  chk "java-common-ms clone: hub-scan left every mtime unchanged, wrote no plane" \
    '[ "$jc_before" = "$(snap "$E/java-common-ms")" ] && [ ! -e "$E/java-common-ms/.claude/claudehut/index" ]'
  chk "source repos' .git/index untouched" '[ "$src_idx" = "$(for r in va-ms payment-orchestrator-ms core-ledger-ms payment-gateway-ms java-common-ms; do stat -f %m "$EWS/$r/.git/index" 2>/dev/null || stat -c %Y "$EWS/$r/.git/index"; done)" ]'
  ix "$E/ewallet-knowledge" links
  printf '%s\n' "$OUT" | sed 's/^/    /'
fi

# ---------------------------------------------------------------- 8. init-driven ---------------------------------
echo "== 8. init-driven: build name ≠ repo dir, inner hub spelling, yml-only consumer =="
WS="$W/ws2"; K="$WS/knowledge"; KH="$K/.claude/claudehut/hub"; INIT="$ROOT/bin/claudehut-init"
mk() { # $1 dir, $2 rootProject.name — a gradle repo with group io.x (both declare it: no lib owner)
  mkdir -p "$WS/$1/src/main/resources" "$WS/$1/src/main/java/com/acme/k"
  printf "rootProject.name = '%s'\n" "$2" > "$WS/$1/settings.gradle"
  printf "plugins { id 'java' }\ngroup = 'io.x'\ndependencies { implementation 'org.springframework.kafka:spring-kafka' }\n" > "$WS/$1/build.gradle"
}
mk pay-ms pay-service
printf 'spring:\n  r2dbc:\n    url: ${SPRING_R2DBC_URL:r2dbc:postgresql://localhost:5432/pay_db}\n' > "$WS/pay-ms/src/main/resources/application.yml"
printf 'package com.acme.k;\n\nimport org.springframework.kafka.core.KafkaTemplate;\nimport org.springframework.stereotype.Component;\n\n@Component\npublic class DoneProducer {\n  private final KafkaTemplate<String, String> kafkaTemplate;\n\n  public DoneProducer(KafkaTemplate<String, String> kafkaTemplate) {\n    this.kafkaTemplate = kafkaTemplate;\n  }\n\n  public void publish(String v) {\n    kafkaTemplate.send("pay.done.v1", v);\n  }\n}\n' \
  > "$WS/pay-ms/src/main/java/com/acme/k/DoneProducer.java"
mk wal-ms wal-service
# reactor-kafka style: the consumer topic lives only in yml; the cdc block names pay_db (never a shared-db edge)
printf 'spring:\n  r2dbc:\n    url: ${SPRING_R2DBC_URL:r2dbc:postgresql://localhost:5432/wal_db}\nclients:\n  pay:\n    base-url: ${PAY_SERVICE_URL:http://localhost:8081}\nkafka:\n  consumer:\n    done:\n      topic: ${PAY_DONE_TOPIC:pay.done.v1}\ncdc:\n  url: ${CDC_URL:jdbc:postgresql://localhost:5432/pay_db}\n' \
  > "$WS/wal-ms/src/main/resources/application.yml"
printf 'clients:\n  pay:\n    base-url: ${PAY_SERVICE_URL:http://localhost:9999}\n' > "$WS/wal-ms/src/main/resources/application-test.yml"
printf 'package com.acme.k;\n\npublic class Wallet {}\n' > "$WS/wal-ms/src/main/java/com/acme/k/Wallet.java"
for r in pay-ms wal-ms; do
  git -C "$WS/$r" init -q -b main; git -C "$WS/$r" config commit.gpgsign false; git -C "$WS/$r" add -A; git -C "$WS/$r" commit -qm base --no-verify
done
# (a) --hub <inner dir> on a new hub; (b) CLAUDEHUT_HUB=<inner dir> — both must name the one hub root
( cd "$WS/pay-ms" && CLAUDE_PLUGIN_ROOT="$ROOT" "$INIT" --hub ../knowledge/.claude/claudehut/hub --language vi --git-hooks no >"$W/init-pay.log" 2>&1 )
( cd "$WS/wal-ms" && CLAUDEHUT_HUB="$KH/" CLAUDE_PLUGIN_ROOT="$ROOT" "$INIT" --mode microservice --git-hooks no >"$W/init-wal.log" 2>&1 )
chk "init with the inner hub dir (--hub and CLAUDEHUT_HUB) creates no nested hub" '[ -d "$KH" ] && [ ! -e "$KH/.claude" ]'
chk "both topologies record hub=../knowledge, no language (inherit hub.json vi)" \
  '[ "$(jq -c "[.hub, has(\"language\"), .service]" "$WS/pay-ms/.claude/claudehut/topology.json")" = "[\"../knowledge\",false,\"pay-service\"]" ] && [ "$(jq -c "[.hub, has(\"language\")]" "$WS/wal-ms/.claude/claudehut/topology.json")" = "[\"../knowledge\",false]" ] && [ "$(jq -r .language "$KH/hub.json")" = vi ]'
chk "services.json keys by build name, path by repo dir" \
  '[ "$(jq -c "[.\"pay-service\".path, .\"wal-service\".path]" "$KH/services.json")" = "[\"../pay-ms\",\"../wal-ms\"]" ]'
SL="$KH/service-links.json"
chk "env joins the repo dir: wal-service → pay-service http via PAY_SERVICE_URL high, application.yml evidence first" \
  'jq -e "any(.edges[]; .from==\"wal-service\" and .to==\"pay-service\" and .type==\"http\" and .via==\"PAY_SERVICE_URL\" and .confidence==\"high\" and .evidence[0]==\"wal-ms/src/main/resources/application.yml:6\")" "$SL" >/dev/null'
chk "yml-only consumer topic joins the producer: pay-service → wal-service kafka pay.done.v1 medium" \
  'jq -e "any(.edges[]; .from==\"pay-service\" and .to==\"wal-service\" and .type==\"kafka\" and .via==\"pay.done.v1\" and .confidence==\"medium\" and any(.evidence[]; . == \"wal-ms/src/main/resources/application.yml:10\"))" "$SL" >/dev/null'
nbad=0
while read -r e; do f="${e%:*}"; [ -f "$WS/$f" ] || { nbad=$((nbad+1)); echo "    missing: $e"; }; done \
  < <(jq -r '.edges[].evidence[], .unresolved[].at' "$SL")
chk "every evidence path resolves from the workspace (<repo dir>/<file>)" '[ "$nbad" = 0 ]'
chk "a cdc connector URL is not a shared-db edge; a group both services declare names no lib owner" \
  'jq -e "[.edges[] | select(.type==\"db\" or .type==\"lib\")] | length == 0" "$SL" >/dev/null && jq -e "(._suggested.lib_owner // {}) | has(\"io.x\") | not" "$KH/aliases.json" >/dev/null'
chk "hub .gitignore ignores .aliases.sha1" 'grep -qx ".aliases.sha1" "$KH/.gitignore"'
ix "$WS/wal-ms" svc pay-ms
chk "svc <repo dir> answers for the build-named service" '[[ "$OUT" == "# pay-service (hub"* ]]'
ix "$WS/wal-ms" links --service pay-ms --json
chk "links --service <repo dir> → the edges of pay-service" '[ "$(jq ".edges | length" <<<"$OUT")" = 2 ]'
ix "$WS/wal-ms" find Done --svc pay-ms
chk "find --svc <repo dir> → rows in pay-ms" '[[ "$OUT" == *"$WS/pay-ms/src/main/java/com/acme/k/DoneProducer.java:"* ]]'
HX="$ROOT/scripts/hint-explore.sh"
hint() { printf '%s' "$2" | CLAUDE_PROJECT_DIR="$WS/wal-ms" CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDEHUT_HUB="$1" bash "$HX" 2>/dev/null; }
H1="$(hint "$KH" '{"session_id":"hx1","tool_name":"Read","tool_input":{"file_path":"'"$WS"'/pay-ms/build.gradle"}}')"
chk "hint-explore with CLAUDEHUT_HUB=<inner dir>: sibling Read → one vi line (hub language inherited)" \
  '[ "$(printf "%s\n" "$H1" | grep -c .)" = 1 ] && [[ "$H1" == *"pay-service là service khác"* ]]'
jq '.hub = "../knowledge/.claude/claudehut/hub"' "$WS/wal-ms/.claude/claudehut/topology.json" > "$W/t.json" && cp "$W/t.json" "$WS/wal-ms/.claude/claudehut/topology.json"
H2="$(hint "" '{"session_id":"hx2","tool_name":"Grep","tool_input":{"pattern":"pay-service.*Done"}}')"
H3="$(hint "" '{"session_id":"hx3","tool_name":"Grep","tool_input":{"pattern":"nothing.here"}}')"
H4="$(hint "" '{"session_id":"hx4","tool_name":"Grep","tool_input":{"pattern":"DoneProducer","path":"../pay-ms"}}')"
H5="$(hint "" '{"session_id":"hx5","tool_name":"Grep","tool_input":{"pattern":"pay-ms"}}')"
H6="$(hint "" '{"session_id":"hx6","tool_name":"Grep","tool_input":{"pattern":"wal-ms|wal-service"}}')"
chk "topology.hub=<inner dir>: Grep naming a service → vi line; a pattern naming none → silent" \
  '[[ "$H2" == *"pay-service là service khác"* ]] && [ -z "$H3" ]'
chk "hint-explore: Grep under the sibling repo, or a pattern naming its repo dir → hint for pay-service" \
  '[[ "$H4" == *"pay-service là service khác"* ]] && [[ "$H5" == *"pay-service là service khác"* ]]'
chk "hint-explore: a pattern naming only this repo (its dir wal-ms or its key wal-service) → silent" '[ -z "$H6" ]'

chk "no __pycache__ written into the plugin" '[ -z "$(find "$ROOT/scripts" -name __pycache__ 2>/dev/null)" ]'
echo "hub-tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
