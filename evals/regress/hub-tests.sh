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
#   9. scan then init   a repo hub-scanned by its dir name, then init'd by its build name → one service, one links
#                       file, no doubled edge; hub-sync collapses the doubled services.json 0.12.0 left; an alias
#                       naming the dir resolves to the build-name key
#  10. shared library   kit-lib (a multi-module publisher, no alias, not summer) + cons-x-ms (BOM 1.2.0, explicit,
#                       BOM-managed, versioned-apart module, unpublished test module) + cons-y-ms (Kotlin DSL, catalog
#                       version.ref BOM 1.4.0, gradle.properties version, map notation): exact per-module lib edges with
#                       version + version_src + evidence; svc <library> modules × consumers × versions with SKEW;
#                       links --type lib; find --svc <library> on its surface; HUB.md "Shared libraries"; UA graph
#  11. buckets          d-ms + e-ms (planes) + a workloads dir (aliases.manifests): helm/k8s env values resolve
#                       env → service (image basename, <name>.<namespace>), a deployed app outside the hub →
#                       external:<app>, a public host → external:<host>; another service's datasource → db edge by
#                       deployed schema; a manifest topic env beats the yml default; handler getSupportedTopics(),
#                       publisher route tables and outbox saveEvent topics join; test/local copies, dead config, UI
#                       links (by key name, and by use: values only put into email/template model data, whatever
#                       address the manifest or default holds), a deployed self-address, a topic no consumer names
#                       and an empty topic property are `ignored`; DLT, outbox, wrapper send sites and a prefix the
#                       publisher bypasses are `dynamic`, each with a reason; real clients (WebClient.baseUrl,
#                       RestClient.create, even portal-named or also emailed) keep their edges or stay `unresolved`;
#                       accounting: every client/consumer/producer/prefix row lands in an edge xor exactly one
#                       bucket row; `links` keeps the totals when clipped; no manifest secret leaks
#  12. aliases.ignore   the buckets repos (e-ms copy also names COMPLIANCE_URL → d-ms): a scoped ignore
#                       (d-ms:COMPLIANCE_URL, unresolved → ignored) leaves e-ms's same env an edge; an unscoped env
#                       ignore drops edges; a topic ignore drops the kafka edge (producer + consumer rows); each row
#                       carries "declared in aliases.json: <reason>" and its evidence; accounting stays empty
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
# account <hub dir> — prints every input row of links/<svc>.json that does not end up exactly once: in an edge
# (http: via/also_via of an edge from the service, for a main-profile key; kafka: an edge from/to the service via the
# topic; topic-prefix: its yml line in the evidence of an edge from the service) XOR in exactly one bucket row (by
# its evidence line; kafka by service + topic or prefix). Inputs: HTTP-shaped clients (is_http_client), client
# targets, Feign/@HttpExchange targets, kafka consumes, kafka produces (topic and prefix). Empty output = accounted.
account() { python3 - "$1" "$ROOT/scripts/index" <<'PY'
import glob, json, os, sys
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[2])
import hub
h = sys.argv[1]
sl = json.load(open(os.path.join(h, "service-links.json")))
edges, rows = sl["edges"], [u for b in ("unresolved", "ignored", "dynamic") for u in sl[b]]
bad = []
def out(what, n_edge, n_row):
    if not ((n_edge and n_row == 0) or (not n_edge and n_row == 1)):
        bad.append("%s: edges=%s bucket rows=%d" % (what, bool(n_edge), n_row))
for f in sorted(glob.glob(os.path.join(h, "links", "*.json"))):
    L = json.load(open(f)); s = L["svc"]; d = hub.repo_dir(L, s)
    ev = lambda at: "%s/%s" % (d, at)
    c = L["contracts"]
    clients = [x for x in c.get("http_clients", []) if hub.is_http_client(x)]
    have = {x["at"] for x in clients}
    clients += [{"env": t.get("env"), "prop": t.get("prop"), "at": t["yml_at"]} for t in c.get("client_targets", [])
                if t.get("yml_at") not in have and hub.is_http_client(t)]
    for x in clients:
        via = x.get("env") or x.get("prop") or x.get("key")
        n_edge = hub.ev_rank(x["at"]) < 2 and any(e["type"] == "http" and e["from"] == s and
                                                  (e["via"] == via or via in e.get("also_via", [])) for e in edges)
        out("%s http %s @%s" % (s, via, x["at"]), n_edge, sum(1 for u in rows if u["svc"] == s and u.get("at") == ev(x["at"])))
    for r in L["components"]:
        if r["kind"] == "client" and r.get("target"):
            n_edge = any(e["type"] == "http" and e["from"] == s and any(a == ev("%s:%d" % (r["file"], r["line"]))
                                                                       for a in e["evidence"]) for e in edges)
            out("%s feign %s" % (s, r["target"]), n_edge,
                sum(1 for u in rows if u["svc"] == s and u.get("at") == ev("%s:%d" % (r["file"], r["line"]))))
    kin = lambda u: u["svc"] == s and u.get("kind", "").startswith("kafka")
    for t in sorted({x["topic"] for x in L["kafka"]["consumes"]}):
        out("%s consumes %s" % (s, t), any(e["type"] == "kafka" and e["to"] == s and e["via"] == t for e in edges),
            sum(1 for u in rows if kin(u) and u.get("topic") == t and u["kind"] == "kafka_consume"))
    cons = {x["topic"] for x in L["kafka"]["consumes"]}
    for p in L["kafka"]["produces"]:
        if p.get("topic"):
            t = p["topic"]
            n_edge = any(e["type"] == "kafka" and e["from"] == s and e["via"] == t for e in edges)
            out("%s produces %s" % (s, t), n_edge,  # an internal topic: its consumer row covers the producer side
                sum(1 for u in rows if kin(u) and u.get("topic") == t and (u["kind"] == "kafka_produce"
                                                                           or (t in cons and not n_edge))))
        else:
            out("%s prefix %s" % (s, p["prefix"]), any(e["type"] == "kafka" and e["from"] == s and ev(p["at"][0]) in e["evidence"]
                                                     for e in edges),
                sum(1 for u in rows if kin(u) and u.get("prefix") == p["prefix"]))
print("\n".join(sorted(set(bad))))
PY
}

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
chk "hub-scan adds c-ms (no plane): 3 services, 6 edges (lib per module), 2 unresolved, the self-produced topic ignored, the unconsumed prefix dynamic" \
  '[[ "$OUT" == "hub: synced 3 services, 6 edges (http 2, kafka 1, lib 2, db 1), 2 unresolved, 1 ignored, 1 dynamic"* ]]'
chk "the self-produced topic is ignored as internal, with its reason (never dropped silently)" \
  '[ "$(jq -c "[.ignored[] | [.svc, .kind, .topic, .reason]]" "$H/service-links.json")" = "[[\"b-ms\",\"kafka_consume\",\"b.internal.v1\",\"internal topic: b-ms produces and consumes b.internal.v1 itself\"]]" ]'
chk "the c. prefix nobody consumes is dynamic with its reason, not unresolved" \
  'jq -e "[.dynamic[] | select(.prefix==\"c.\" and (.reason|test(\"no other registered service consumes\")))] | length == 1" "$H/service-links.json" >/dev/null'
ACC="$(account "$H")"
chk "accounting (3 repos): every input row is in an edge xor exactly one bucket row${ACC:+ — $ACC}" '[ -z "$ACC" ]'
chk "services.json: c-ms has_plane=false, a-ms/b-ms true, paths relative to the hub root" \
  '[ "$(jq -c "[.\"a-ms\".has_plane, .\"b-ms\".has_plane, .\"c-ms\".has_plane, .\"c-ms\".path]" "$H/services.json")" = "[true,true,false,\"../c-ms\"]" ]'
GOT="$(jq -S '{edges: .edges, unresolved: .unresolved}' "$H/service-links.json")"; WANT="$(jq -S . "$FX/expected-links.json")"
chk "edge + unresolved set == expected-links.json (exact)" '[ "$GOT" = "$WANT" ]'
[ "$GOT" = "$WANT" ] || diff <(printf '%s\n' "$WANT") <(printf '%s\n' "$GOT") | head -20
chk "reactor-kafka (hub-scan): XReactiveConsumer → high consume of x.v1 via its props field's yml key; the receiver factory (param only) emits no listener" \
  'jq -e "any(.kafka.consumes[]; .topic==\"x.v1\" and .at==[\"src/main/java/com/acme/c/kafka/XReactiveConsumer.java:15\",\"src/main/resources/application.yml:14\"])" "$H/links/c-ms.json" >/dev/null && jq -e "[.components[] | select(.kind==\"listener\" and (.file|test(\"KafkaConfigUtil\")))] | length == 0" "$H/links/c-ms.json" >/dev/null'
chk "no edge from r2dbc/redis/SERVER_HOST/LOG_LEVEL/self-topic/offset topics" \
  '! jq -e "[.edges[] | .via] | any(test(\"R2DBC|REDIS|SERVER_HOST|LOG_LEVEL|b.internal|offsets|schema.history\"))" "$H/service-links.json" >/dev/null'
chk "HUB.md ≤3072 B, lists 3 services, the 4 non-lib edges and one Shared libraries line" \
  '[ "$(wc -c < "$H/HUB.md")" -le 3072 ] && grep -q "c-ms \`../c-ms\`.*(hub-scan)" "$H/HUB.md" && [ "$(grep -c "^- .* → " "$H/HUB.md")" = 4 ] && grep -qx "\- java-common-ms (io.f8a.summer): 2 module(s) used by 1 service(s); BOM 0.3.22" "$H/HUB.md"'
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
chk "graph nodes: service:a-ms/b-ms/c-ms + the unregistered lib owner, topic:x.v1, table:shared_db, one module per summer artifact, resource:external:*" \
  '[ "$(jq -c "[.nodes[].id]" "$G")" = "[\"module:io.f8a.summer:summer-kafka-consumer\",\"module:io.f8a.summer:summer-platform\",\"resource:external:api.partner.example.com\",\"service:a-ms\",\"service:b-ms\",\"service:c-ms\",\"service:java-common-ms\",\"table:shared_db\",\"topic:x.v1\"]" ]'
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
LONGBIN="$W/$(printf 'p%.0s' $(seq 1 300))/bin/claudehut-index"
OUT="$(cd "$W/hubrepo" && CLAUDEHUT_INDEX_BIN="$LONGBIN" python3 -B "$ROOT/scripts/index/claudehut_index.py" brief --json --budget 600 2>"$W/stderr")"
chk "brief --json at the hub keeps the contract and the budget when the checkout path is long (${#LONGBIN} B CLI path)" \
  '[ "$(jq -r "[.budget, (.bytes <= 600), (.sections[0].name), (.markdown == ([.sections[].lines[]] | join(\"\\n\")))] | join(\",\")" <<<"$OUT")" = "600,true,banner,true" ]'
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
  chk "AC-9: every lib edge goes to java-common-ms, one per summer module, with a version" \
    'jq -e "[.edges[] | select(.type==\"lib\")] | length > 4 and all(.[]; .to == \"java-common-ms\" and (.module|startswith(\"summer-\")) and (.version != null or .bom_version != null))" "$EH/service-links.json" >/dev/null'
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

# ---------------------------------------------------------------- 9. scan then init ------------------------------
echo "== 9. one repo, two names: hub-scanned by dir (ekyc-int-ms), then init'd by build name (kyc-ms) =="
WS="$W/ws3"; KH="$WS/knowledge/.claude/claudehut/hub"
mk() { # $1 dir, $2 rootProject.name
  mkdir -p "$WS/$1/src/main/resources" "$WS/$1/src/main/java/com/acme/k"
  printf "rootProject.name = '%s'\n" "$2" > "$WS/$1/settings.gradle"
  printf "plugins { id 'java' }\ndependencies { implementation 'org.springframework.kafka:spring-kafka' }\n" > "$WS/$1/build.gradle"
}
mk acc-ms acc-ms
printf 'package com.acme.k;\n\nimport org.springframework.kafka.annotation.KafkaListener;\nimport org.springframework.stereotype.Component;\n\n@Component\npublic class KycListener {\n  @KafkaListener(topics = "kyc.done.v1")\n  public void on(String v) {}\n}\n' \
  > "$WS/acc-ms/src/main/java/com/acme/k/KycListener.java"
mk ekyc-int-ms kyc-ms
printf 'clients:\n  acc:\n    base-url: ${ACC_SERVICE_URL:http://localhost:8082}\n' > "$WS/ekyc-int-ms/src/main/resources/application.yml"
printf 'package com.acme.k;\n\nimport org.springframework.kafka.core.KafkaTemplate;\nimport org.springframework.stereotype.Component;\n\n@Component\npublic class KycProducer {\n  private final KafkaTemplate<String, String> kafkaTemplate;\n\n  public KycProducer(KafkaTemplate<String, String> kafkaTemplate) {\n    this.kafkaTemplate = kafkaTemplate;\n  }\n\n  public void publish(String v) {\n    kafkaTemplate.send("kyc.done.v1", v);\n  }\n}\n' \
  > "$WS/ekyc-int-ms/src/main/java/com/acme/k/KycProducer.java"
for r in acc-ms ekyc-int-ms; do
  git -C "$WS/$r" init -q -b main; git -C "$WS/$r" config commit.gpgsign false; git -C "$WS/$r" add -A; git -C "$WS/$r" commit -qm base --no-verify
done
( cd "$WS/acc-ms" && CLAUDE_PLUGIN_ROOT="$ROOT" "$INIT" --hub ../knowledge --language en --git-hooks no >"$W/init-acc.log" 2>&1 )
ix "$WS/knowledge" hub-scan --hub . --repo ../ekyc-int-ms   # what claudehut-migrate does for a repo without a plane
SL="$KH/service-links.json"; n_scan="$(jq '.edges | length' "$SL")"
chk "hub-scan keys the repo by its dir: ekyc-int-ms → acc-ms http + kafka" \
  '[ "$n_scan" = 2 ] && [ "$(jq -c "[.edges[] | .from] | unique" "$SL")" = "[\"ekyc-int-ms\"]" ]'
one_repo() { # $1 label — exactly one entry for ../ekyc-int-ms (kyc-ms), links/ = registered keys, no doubled edge
  chk "$1: services.json holds one entry for ../ekyc-int-ms, keyed kyc-ms" \
    '[ "$(jq -c "[to_entries[] | select(.value.path == \"../ekyc-int-ms\") | .key]" "$KH/services.json")" = "[\"kyc-ms\"]" ]'
  chk "$1: links/ holds acc-ms.json and kyc-ms.json only" '[ "$(ls "$KH/links" | tr "\n" " ")" = "acc-ms.json kyc-ms.json " ]'
  chk "$1: $n_scan edges, none doubled, none naming the dir key" \
    '[ "$(jq ".edges | length" "$SL")" = "$n_scan" ] && jq -e "(.edges | map([.from,.to,.type,.via]) | unique | length) == (.edges | length) and all(.edges[]; .from != \"ekyc-int-ms\" and .to != \"ekyc-int-ms\")" "$SL" >/dev/null'
}
( cd "$WS/ekyc-int-ms" && CLAUDE_PLUGIN_ROOT="$ROOT" "$INIT" --mode microservice --hub ../knowledge --git-hooks no >"$W/init-kyc.log" 2>&1 )
one_repo "init after hub-scan"
chk "init logs the dropped entry" 'grep -q "registered kyc-ms .*dropped the old entry for the same repo: ekyc-int-ms" "$W/init-kyc.log"'
# The state 0.12.0 left behind (init added kyc-ms beside ekyc-int-ms): hub-sync collapses it. A user alias that
# still names the dir (topic_owner → ekyc-int-ms) resolves to kyc-ms, not to a ghost node.
jq '. + {"ekyc-int-ms": {path: "../ekyc-int-ms", has_plane: false}}' "$KH/services.json" > "$W/s.json" && cp "$W/s.json" "$KH/services.json"
cp "$KH/links/kyc-ms.json" "$KH/links/ekyc-int-ms.json"
printf '{"env":{},"topic_owner":{"kyc.done.v1":"ekyc-int-ms"},"db_owner":{}}\n' > "$KH/aliases.json"
ix "$WS/knowledge" hub-sync --hub .
chk "hub-sync on a doubled services.json reports 2 services" '[[ "$OUT" == "hub: synced 2 services, $n_scan edges"* ]]'
one_repo "hub-sync dedupe"
chk "topic_owner naming the repo dir → kyc-ms → acc-ms kafka high" \
  'jq -e "any(.edges[]; .from==\"kyc-ms\" and .to==\"acc-ms\" and .type==\"kafka\" and .confidence==\"high\")" "$SL" >/dev/null'

# ---------------------------------------------------------------- 10. shared library ---------------------------
echo "== 10. shared library: per-module lib edges, versions, skew, library surface =="
WS="$W/ws4"; mkdir -p "$WS/kh"; git -C "$WS/kh" init -q -b main; KH="$WS/kh/.claude/claudehut/hub"
for r in kit-lib cons-x-ms cons-y-ms; do
  cp -R "$FX/$r" "$WS/$r"; git -C "$WS/$r" init -q -b main; git -C "$WS/$r" config commit.gpgsign false
  git -C "$WS/$r" add -A; git -C "$WS/$r" commit -qm base --no-verify
done
mkdir -p "$WS/kit-lib/.claude/claudehut"; "$CLI" update --plane "$WS/kit-lib/.claude/claudehut" >/dev/null  # an indexed library
ix "$WS/kh" hub-scan --hub . --repo ../kit-lib --repo ../cons-x-ms --repo ../cons-y-ms
SL="$KH/service-links.json"
chk "3 services, 9 lib edges (one per consumer × module), none to a group alias" '[[ "$OUT" == "hub: synced 3 services, 9 edges (http 0, kafka 0, lib 9, db 0), 0 unresolved"* ]]'
LIBE="$(jq -c '[.edges[] | select(.type=="lib") | [.from, .to, .module, .version, .version_src, .bom_version, (.bom // false), (.scope // "main"), (.missing // false), .evidence]]' "$SL")"
WANT='[["cons-x-ms","kit-lib","kit-core","1.3.0","explicit",null,false,"main",false,["cons-x-ms/build.gradle:9"]],["cons-x-ms","kit-lib","kit-kafka",null,"bom","1.2.0",false,"main",false,["cons-x-ms/build.gradle:10","cons-x-ms/build.gradle:7"]],["cons-x-ms","kit-lib","kit-legacy","1.2.0","bom","1.2.0",false,"test",true,["cons-x-ms/build.gradle:11","cons-x-ms/build.gradle:7"]],["cons-x-ms","kit-lib","kit-platform","1.2.0","explicit",null,true,"main",false,["cons-x-ms/build.gradle:7"]],["cons-x-ms","kit-lib","kit-rest-autoconfigure","1.2.0","bom","1.2.0",false,"main",false,["cons-x-ms/build.gradle:8","cons-x-ms/build.gradle:7"]],["cons-y-ms","kit-lib","kit-core","1.4.0","explicit",null,false,"main",false,["cons-y-ms/build.gradle.kts:12"]],["cons-y-ms","kit-lib","kit-kafka","2.0.1","property",null,false,"main",false,["cons-y-ms/build.gradle.kts:11"]],["cons-y-ms","kit-lib","kit-platform","1.4.0","catalog",null,true,"main",false,["cons-y-ms/build.gradle.kts:9"]],["cons-y-ms","kit-lib","kit-rest-autoconfigure","1.4.0","bom","1.4.0",false,"main",false,["cons-y-ms/build.gradle.kts:10","cons-y-ms/build.gradle.kts:9"]]]'
chk "lib edges == expected: module, version, version_src (explicit/bom/catalog/property), BOM, test scope, unpublished module, evidence" '[ "$LIBE" = "$WANT" ]'
[ "$LIBE" = "$WANT" ] || { echo "    want $WANT"; echo "    got  $LIBE"; }
nbad=0
while read -r e; do f="${e%:*}"; ln="${e##*:}"; { [ -f "$WS/$f" ] && [ "$(wc -l < "$WS/$f")" -ge "$ln" ]; } || { nbad=$((nbad+1)); echo "    missing: $e"; }; done \
  < <(jq -r '.edges[].evidence[]' "$SL")
chk "every lib evidence path exists with that line" '[ "$nbad" = 0 ]'
ix "$WS/kh" svc kit-lib --hub .
chk "svc kit-lib ≤2500 B: surface counts, modules × consumers × versions, SKEW, BOM-managed, unpublished, newer" \
  '[ "$(printf "%s\n" "$OUT" | wc -c)" -le 2500 ] && for w in "Library io.acme.kit @1.4.0 · 4 modules · module 4, autoconfig 3, properties 2, annotation 1, spi 1, bean 1 — find --svc kit-lib <term>" \
     "- [bom] platform 2 svc SKEW: 1.2.0 cons-x-ms · 1.4.0 cons-y-ms" "- core 2 svc SKEW: 1.3.0 cons-x-ms · 1.4.0 cons-y-ms" \
     "- kafka 2 svc SKEW: bom 1.2.0 cons-x-ms · 2.0.1 cons-y-ms" "- rest-autoconfigure 2 svc (bom)" "Not published by this repo: legacy"; do
     printf "%s\n" "$OUT" | grep -qxF -- "$w" || { echo "    missing line: $w"; exit 1; }; done && ! printf "%s" "$OUT" | grep -q "Newer than"'
ix "$WS/kh" svc cons-x-ms --hub .
chk "svc <consumer> lists the library modules it uses with their versions" \
  '[[ "$OUT" == *"Libs from kit-lib: kit-core 1.3.0, kit-kafka bom 1.2.0, kit-legacy 1.2.0 [test], kit-platform 1.2.0, kit-rest-autoconfigure 1.2.0"* ]]'
ix "$WS/kh" links --type lib --service cons-y-ms --hub .
chk "links --type lib --service: one line per module with its version and evidence" \
  '[ "$(printf "%s\n" "$OUT" | grep -c "^cons-y-ms → kit-lib lib via io.acme.kit:")" = 4 ] && printf "%s\n" "$OUT" | grep -qxF "cons-y-ms → kit-lib lib via io.acme.kit:kit-kafka @2.0.1 (high) cons-y-ms/build.gradle.kts:11"'
ix "$WS/kh" links --module rest-autoconfigure --hub .
chk "links --module <short name> → every consumer of that module with its version (the impact of a change)" \
  '[ "$(printf "%s\n" "$OUT" | grep -c "lib via io.acme.kit:kit-rest-autoconfigure @")" = 2 ] && [[ "$OUT" == *"cons-x-ms → kit-lib lib via io.acme.kit:kit-rest-autoconfigure @1.2.0 (high) cons-x-ms/build.gradle:8"* ]] && [[ "$OUT" == *"2 edge(s)"* ]]'
ix "$WS/kh" links --hub .
chk "links (all types) folds lib edges into one line per consumer → library" \
  '[ "$(printf "%s\n" "$OUT" | grep -c " lib ")" = 2 ] && [[ "$OUT" == *"cons-x-ms → kit-lib lib 5 module(s): (links --type lib --service cons-x-ms)"* ]]'
ix "$WS/kh" find --svc kit-lib --hub . kit.rest.retry
chk "find --svc <library> finds a property key → the properties class, absolute path, module" \
  '[[ "$OUT" == "properties io.acme.kit.rest.KitRestProperties prefix=kit.rest (4 keys) [kit-rest-autoconfigure] $WS/kit-lib/rest/rest-autoconfigure/src/main/java/io/acme/kit/rest/KitRestProperties.java:8" ]]'
ix "$WS/kh" find --svc kit-lib --hub . --kind autoconfig "*"
chk "find --svc <library> --kind autoconfig → the 3 registered auto-configurations (imports + spring.factories)" '[ "$(printf "%s\n" "$OUT" | grep -c "^autoconfig ")" = 3 ]'
chk "HUB.md: a Shared libraries line with BOM skew and module skew; lib edges not in the Edges list; ≤3072 B" \
  'grep -qxF -- "- kit-lib (io.acme.kit @1.4.0): 5 module(s) used by 2 service(s); BOM 1.2.0…1.4.0 (2 versions, skew); skew: kit-core, kit-kafka" "$KH/HUB.md" && ! grep -q "^- .* → .* · lib" "$KH/HUB.md" && [ "$(wc -c < "$KH/HUB.md")" -le 3072 ]'
G4="$KH/.understand-anything/knowledge-graph.json"
chk "graph: module node per library artifact; consumers depend_on, the library contains (not the unpublished one)" \
  '[ "$(jq "[.edges[] | select(.type==\"depends_on\")] | length" "$G4")" = 9 ] && [ "$(jq -c "[.edges[] | select(.type==\"contains\") | .target]" "$G4")" = "[\"module:io.acme.kit:kit-core\",\"module:io.acme.kit:kit-kafka\",\"module:io.acme.kit:kit-platform\",\"module:io.acme.kit:kit-rest-autoconfigure\"]" ]'
if command -v node >/dev/null 2>&1 && [ -f "$UA/packages/core/dist/schema.js" ]; then
  n="$(cd "$UA/packages/core" && node --input-type=module -e 'import { validateGraph, sanitizeGraph } from "./dist/schema.js"; import fs from "fs";
    const g = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); const r = validateGraph(g);
    console.log(r.success && g.edges.length === r.data.edges.length && JSON.stringify(sanitizeGraph(g)) === JSON.stringify(g) ? r.issues.length : -1);' "$G4")"
  chk "shared-library graph: UA validateGraph 0 issues, nothing dropped, sanitizeGraph no-op" '[ "$n" = 0 ]'
fi
cp "$SL" "$W/sl.bak"   # 15 peers into kit-lib: "Used by:" shows 14 and says how many it left off
jq '.edges += [range(1;14) as $i | {from: ("peer-\($i)-ms"), to: "kit-lib", type: "http", via: "GET /p", evidence: [], confidence: "high"}]' \
  "$W/sl.bak" > "$SL"
ix "$WS/kh" svc kit-lib --hub .
chk "svc with 15 inbound peers: Used by lists 14 and ends with +1" \
  '[ "$(printf "%s\n" "$OUT" | grep "^Used by: " | grep -o "(" | wc -l | tr -d " ")" = 14 ] && printf "%s\n" "$OUT" | grep -q "^Used by: .* +1$"'
cp "$W/sl.bak" "$SL"
mv "$WS/kit-lib/.claude" "$W/kit-plane"; ix "$WS/kh" hub-sync --hub .
chk "a hub-scanned library (no plane) yields the same surface and the same lib edges" \
  '[ "$(jq -c "[.edges[] | select(.type==\"lib\") | [.from, .to, .module, .version, .version_src, .bom_version, (.bom // false), (.scope // \"main\"), (.missing // false), .evidence]]" "$SL")" = "$WANT" ] && [ "$(jq "[.components[] | select(.kind==\"autoconfig\" or .kind==\"properties\" or .kind==\"bean\")] | length" "$KH/links/kit-lib.json")" = 6 ]'

# ---------------------------------------------------------------- 11. buckets ------------------------------------
echo "== 11. buckets: manifests, handler/publisher/outbox topics, ignored/dynamic with reasons =="
BW="$W/bk"; mkdir -p "$BW"; BH="$BW/kh/.claude/claudehut/hub"
for r in d-ms e-ms; do
  cp -R "$FX/buckets/$r" "$BW/$r"; git -C "$BW/$r" init -q -b main; git -C "$BW/$r" config commit.gpgsign false
  git -C "$BW/$r" add -A; git -C "$BW/$r" commit -qm base --no-verify
  mkdir -p "$BW/$r/.claude/claudehut"; "$CLI" update --plane "$BW/$r/.claude/claudehut" >/dev/null
done
cp -R "$FX/buckets/workloads" "$BW/workloads"
mkdir -p "$BH"; git -C "$BW/kh" init -q -b main
printf '{"env":{"APP_SMS_URL":"e-ms"},"topic_owner":{},"db_owner":{},"manifests":"../workloads"}\n' > "$BH/aliases.json"
al_before="$(sha "$BH/aliases.json")"
ix "$BW/kh" hub-sync --hub . --repo ../d-ms --repo ../e-ms
chk "2 planes: 2 unresolved, 9 ignored, 4 dynamic" '[[ "$OUT" == "hub: synced 2 services, "*", 2 unresolved, 9 ignored, 4 dynamic"* ]]'
BL="$BH/service-links.json"
edge() { jq -e --arg f "$1" --arg t "$2" --arg ty "$3" --arg v "$4" --arg c "$5" \
  'any(.edges[]; .from==$f and .to==$t and .type==$ty and .via==$v and .confidence==$c)' "$BL" >/dev/null; }
chk "helm env → in-cluster name.namespace → k8s Deployment image basename → e-ms (manifest line as evidence)" \
  'edge d-ms e-ms http E_SVC_URL high && jq -e "any(.edges[]; .via==\"E_SVC_URL\" and any(.evidence[]; . == \"workloads/deploy/dev/d-ms/values.yaml:9\"))" "$BL" >/dev/null'
chk "a deployed app the hub lacks → external:<app>; a public manifest host → external:<host>" \
  'edge d-ms external:stub-bank http MOCK_BANK_URL high && edge d-ms external:api.partner.example.com http PARTNER_URL high'
chk "manifest targets all external: the yml default's public host stays an edge; a localhost default adds none" \
  'edge d-ms external:sandbox.partner.example.com http PARTNER_URL high && [ "$(jq "[.edges[] | select(.via==\"MOCK_BANK_URL\")] | length" "$BL")" = 1 ]'
chk "another service's datasource URL → db edge to the owner of its deployed schema; no http edge" \
  'edge d-ms e-ms db e_schema medium && ! jq -e "any(.edges[]; .via==\"REPORT_DATASOURCES_E_URL\")" "$BL" >/dev/null'
chk "kafka: handler getSupportedTopics() ← publisher route table (props getter) e.cmd.v1 high; saveEvent explicit topic f.cmd.v1 high" \
  'edge d-ms e-ms kafka e.cmd.v1 high && edge d-ms e-ms kafka f.cmd.v1 high'
chk "manifest topic env beats the stale yml default; 3-arg saveEvent = topic-prefix + type; the prefix counts as consumed" \
  'edge d-ms e-ms kafka d.link.notify medium && ! jq -e "any(.edges[]; .via==\"stale_link_topic\") or any(.unresolved[]; .topic==\"stale_link_topic\") or any(.dynamic[]; .prefix==\"d.\")" "$BL" >/dev/null'
chk "unresolved = exactly the bound clients with no deployed value and no counterpart (a portal-named key feeding WebClient.baseUrl is a client, not a UI link)" \
  '[ "$(jq -c "[.unresolved[] | [.svc, .kind, .env]]" "$BL")" = "[[\"d-ms\",\"http_client\",\"COMPLIANCE_URL\"],[\"d-ms\",\"http_client\",\"PORTAL_GATEWAY_URL\"]]" ]'
chk "ignored: test copy, test-only (its alias never applies), dead map entry, UI links (by key name; by use), a deployed self-address, a topic no consumer names, disabled topic — each with a reason" \
  '[ "$(jq -c "[.ignored[] | [(.env // .expr // .topic), (.reason|split(\":\")[0]|split(\" \")[0:2]|join(\" \"))]] | sort" "$BL")" = "[[\"APP_BACKOFFICE_URL\",\"UI link\"],[\"APP_MERCHANT_PORTAL_URL\",\"UI link\"],[\"APP_SMS_URL\",\"test/local profile\"],[\"D_CALLBACK_URL\",\"self\"],[\"E_SVC_URL\",\"test/local profile\"],[\"GHOST_SERVICE_URL\",\"unused config\"],[\"PORTAL_LOGIN_URL\",\"UI link\"],[\"d.audit.v1\",\"no registered\"],[\"opsTopic\",\"topic property\"]]" ] && ! jq -e "any(.edges[]; .via==\"APP_SMS_URL\")" "$BL" >/dev/null'
chk "the test copy names its main-profile key" 'jq -e "any(.ignored[]; .env==\"E_SVC_URL\" and .reason==\"test/local profile copy of d-ms/src/main/resources/application.yml:9\")" "$BL" >/dev/null'
chk "dynamic: the DLT publisher, the outbox publisher and the topic-parameter wrapper (with the topics their callers name), the bypassed prefix" \
  '[ "$(jq -c "[.dynamic[] | [(.at|split(\"/\")|last|split(\":\")[0]), (.reason|split(\":\")[0]), (.topics // [])]] | sort" "$BL")" = "[[\"DltPublisher.java\",\"dead-letter/replay publisher\",[]],[\"EOutboxEventPublisher.java\",\"outbox publisher\",[\"e.done.v1\"]],[\"GenericProducer.java\",\"producer wrapper\",[\"d.link.notify\",\"e.cmd.v1\",\"f.cmd.v1\"]],[\"application.yml\",\"outbox topic-prefix superseded\",[]]]" ]'
chk "UI link by use: a URL only put into email/template model data (@Value field; props getter chain into Map.of + a *MailContext) is ignored — neither its manifest host nor its public default becomes an edge" \
  '! jq -e "any(.edges[]; .via==\"APP_BACKOFFICE_URL\" or .via==\"APP_MERCHANT_PORTAL_URL\" or .to==\"external:cms.shop.example.net\" or .to==\"external:merchant.portal.example.com\")" "$BL" >/dev/null && jq -e "[.ignored[] | select(.env==\"APP_MERCHANT_PORTAL_URL\" and (.reason|test(\"UserMailer.java:31\")))] | length == 1" "$BL" >/dev/null'
chk "real clients keep their edges: a portal-named key feeding WebClient.baseUrl, a URL used in an email AND by RestClient.create" \
  'edge d-ms external:portal-api.partner.example.com http PARTNER_PORTAL_URL high && edge d-ms external:help.example.org http APP_HELP_URL high'
chk "a topic-prefix the publisher bypasses (routes e.done.v1 explicitly) keeps a dynamic row naming the routed topic" \
  'edge e-ms d-ms kafka e.done.v1 high && jq -e "[.dynamic[] | select(.prefix==\"e.\" and (.reason|test(\"superseded.*e.done.v1 → d-ms\")))] | length == 1" "$BL" >/dev/null'
chk "a prefix-composed topic (3-arg saveEvent) cites the prefix line on its edge" \
  'jq -e "any(.edges[]; .via==\"d.link.notify\" and any(.evidence[]; . == \"d-ms/src/main/resources/application.yml:42\"))" "$BL" >/dev/null'
ACC="$(account "$BH")"
chk "accounting: every client/consumer/producer/prefix row is in an edge xor exactly one bucket row${ACC:+ — $ACC}" '[ -z "$ACC" ]'
chk "no manifest secret value (helm env, *.enc.yaml) appears anywhere under the hub dir" \
  '! grep -rqE "fake-pass-ABC123|fake-token-QQQ777|fake-secret-XYZ999" "$BH"'
chk "aliases.json with manifests is user-owned: never rewritten" '[ "$al_before" = "$(sha "$BH/aliases.json")" ]'
chk "HUB.md tail counts every bucket; ≤3072 B" \
  'grep -qxF "Unresolved: 2 (fix with aliases.json) · ignored 9 · dynamic 4 (each with its reason in service-links.json)." "$BH/HUB.md" && [ "$(wc -c < "$BH/HUB.md")" -le 3072 ]'
ix "$BW/kh" links --json
chk "links --json carries ignored + dynamic" '[ "$(printf "%s" "$OUT" | jq -c "[(.unresolved|length), (.ignored|length), (.dynamic|length)]")" = "[2,9,4]" ]'
ix "$BW/kh" links
chk "links footer counts the buckets" 'printf "%s\n" "$OUT" | tail -1 | grep -q " 2 unresolved, 9 ignored, 4 dynamic (links --json)$"'
b1="$(sha "$BL")"; ix "$BW/kh" hub-sync
chk "re-sync byte-identical" '[ "$b1" = "$(sha "$BL")" ]'
python3 - "$BL" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["edges"] += [{"from": "d-ms", "to": "svc-%03d-ms" % i, "type": "http", "via": "SVC_%03d_SERVICE_URL" % i,
                "confidence": "high", "evidence": ["d-ms/src/main/resources/application.yml:%d" % i]} for i in range(300)]
json.dump(d, open(sys.argv[1], "w"))
PY
ix "$BW/kh" links
chk "links keeps the bucket totals when the edge list is clipped (≤6000 B)" \
  'printf "%s\n" "$OUT" | tail -1 | grep -q "^311 edge(s), 2 unresolved, 9 ignored, 4 dynamic (links --json)$" && [ "$(printf "%s" "$OUT" | wc -c)" -le 6000 ]'

# ---------------------------------------------------------------- 12. aliases.ignore -----------------------------
echo "== 12. aliases.ignore: user-declared ignores (scoped / unscoped / topic) =="
IW="$W/ig"; mkdir -p "$IW"; IH="$IW/kh/.claude/claudehut/hub"
for r in d-ms e-ms; do
  cp -R "$FX/buckets/$r" "$IW/$r"
  [ "$r" = e-ms ] && printf 'compliance:\n  url: ${COMPLIANCE_URL:http://d-ms:8080}\n' >> "$IW/e-ms/src/main/resources/application.yml"
  git -C "$IW/$r" init -q -b main; git -C "$IW/$r" config commit.gpgsign false
  git -C "$IW/$r" add -A; git -C "$IW/$r" commit -qm base --no-verify
  mkdir -p "$IW/$r/.claude/claudehut"; "$CLI" update --plane "$IW/$r/.claude/claudehut" >/dev/null
done
cp -R "$FX/buckets/workloads" "$IW/workloads"
mkdir -p "$IH"; git -C "$IW/kh" init -q -b main
cat > "$IH/aliases.json" <<'JSON'
{"env":{"APP_SMS_URL":"e-ms"},"manifests":"../workloads",
 "ignore":{"d-ms:COMPLIANCE_URL":"dead config: legacy compliance API","PARTNER_URL":"vendor sandbox, not tracked",
           "e.cmd.v1":"retired command topic"}}
JSON
ix "$IW/kh" hub-sync --hub . --repo ../d-ms --repo ../e-ms
IL="$IH/service-links.json"
decl() { jq -e --arg s "$1" --arg k "$2" --arg r "$3" --arg at "$4" \
  '[.ignored[] | select(.svc==$s and ((.env // .topic)==$k) and .reason==("declared in aliases.json: " + $r) and ($at=="" or .at==$at))] | length == 1' "$IL" >/dev/null; }
chk "scoped ignore: d-ms COMPLIANCE_URL unresolved → ignored (reason + evidence); e-ms's own COMPLIANCE_URL keeps its edge to d-ms" \
  'decl d-ms COMPLIANCE_URL "dead config: legacy compliance API" d-ms/src/main/resources/application.yml:19 && ! jq -e "any(.unresolved[]; .env==\"COMPLIANCE_URL\")" "$IL" >/dev/null && jq -e "any(.edges[]; .from==\"e-ms\" and .to==\"d-ms\" and .type==\"http\" and .via==\"COMPLIANCE_URL\") and ([.ignored[] | select(.svc==\"e-ms\" and .env==\"COMPLIANCE_URL\")] | length == 0)" "$IL" >/dev/null'
chk "unscoped env ignore: PARTNER_URL makes no edge (manifest host nor yml default) and lands once in ignored" \
  'decl d-ms PARTNER_URL "vendor sandbox, not tracked" "" && ! jq -e "any(.edges[]; .via==\"PARTNER_URL\" or (.also_via // [] | index(\"PARTNER_URL\")))" "$IL" >/dev/null'
chk "topic ignore: e.cmd.v1 makes no kafka edge; the d-ms producer and the e-ms consumer rows are ignored" \
  'decl d-ms e.cmd.v1 "retired command topic" "" && decl e-ms e.cmd.v1 "retired command topic" "" && ! jq -e "any(.edges[]; .type==\"kafka\" and .via==\"e.cmd.v1\") or any(.unresolved[]; .topic==\"e.cmd.v1\")" "$IL" >/dev/null'
ACC="$(account "$IH")"
chk "accounting with declared ignores: empty, and exactly 4 declared rows${ACC:+ — $ACC}" \
  '[ -z "$ACC" ] && [ "$(jq "[.ignored[] | select(.reason|startswith(\"declared in aliases.json: \"))] | length" "$IL")" = 4 ]'
chk "a hub-written aliases.json carries an empty ignore map and a _note documenting it" 'jq -e "(.ignore == {}) and (._note|test(\"ignore maps\"))" "$KH/aliases.json" >/dev/null'

chk "no __pycache__ written into the plugin" '[ -z "$(find "$ROOT/scripts" -name __pycache__ 2>/dev/null)" ]'
echo "hub-tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
