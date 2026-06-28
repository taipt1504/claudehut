#!/usr/bin/env bash
# Unit eval for scripts/merge-learnings.sh — the deterministic learnings engine that replaced the
# learner agent's by-reasoning bookkeeping (v0.5.1). No Claude, free, deterministic.
# Run: evals/merge-learnings-tests.sh   (exit 0 iff all checks pass)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
SH="$ROOT/scripts/merge-learnings.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; }

command -v jq >/dev/null 2>&1 || { echo "jq required"; exit 2; }

new_proj() { T="$(mktemp -d)"; export CLAUDE_PROJECT_DIR="$T"
  mkdir -p "$T/.claude/claudehut" "$T/.claude/rules/framework"; }
store() { echo "$T/.claude/claudehut/learnings.jsonl"; }

echo "== merge-learnings: dedup / append / prune =="
new_proj
cat > "$(store)" <<'EOF'
{"id":"L-0007","ts":"2026-06-17T00:00:00Z","project":"pg-ms","phase":"learn","category":"pitfall","trigger":"blocking|r2dbc|reactive","learning":"existing","evidence":"X:1","confidence":0.7,"hits":2}
{"id":"L-0008","ts":"2020-01-01T00:00:00Z","project":"pg-ms","phase":"learn","category":"note","trigger":"old|stale","learning":"noise","evidence":"none","confidence":0.1,"hits":1}
EOF
cat > "$T/cand.jsonl" <<'EOF'
{"category":"pitfall","trigger":"Reactive, R2DBC, blocking","learning":"dup merges","evidence":"Y:9","confidence":0.6}
{"category":"convention","trigger":"naming|service","learning":"new entry","evidence":"Z:3"}
EOF
R="$("$SH" --candidates "$T/cand.jsonl" --ts 2026-06-17T10:00:00Z)"
[ "$(jq -r '.merged' <<<"$R")" = 1 ] && ok "report: 1 merged" || bad "report merged ($R)"
[ "$(jq -r '.added'  <<<"$R")" = 1 ] && ok "report: 1 added"  || bad "report added ($R)"
[ "$(jq -r '.dropped'<<<"$R")" = 1 ] && ok "report: 1 dropped"|| bad "report dropped ($R)"
[ "$(jq -sc 'map(select(.id=="L-0007"))|.[0]|[.hits,.confidence]' "$(store)")" = "[3,0.75]" ] \
  && ok "dedup by normalized trigger: L-0007 hits 2->3, conf 0.70->0.75" || bad "merge math wrong"
[ -n "$(jq -sc 'map(select(.trigger=="naming|service" and .id=="L-0009"))|.[0]//empty' "$(store)")" ] \
  && ok "append: new entry id L-0009 (max+1)" || bad "append/id-gen wrong"
[ -z "$(jq -sc 'map(select(.id=="L-0008"))|.[0]//empty' "$(store)")" ] \
  && ok "prune: stale L-0008 (conf<0.25,hits<=1,age>90d) dropped" || bad "prune wrong"
[ "$(grep -c . "$(store)")" = 2 ] && ok "store has 2 lines after merge+prune" || bad "line count wrong"
rm -rf "$T"

echo "== merge-learnings: promotion (pitfall hits>=5 & conf>=0.85) =="
new_proj
echo "# JPA rules" > "$T/.claude/rules/framework/jpa.md"
cat > "$(store)" <<'EOF'
{"id":"L-0001","ts":"2026-06-17T00:00:00Z","project":"pg-ms","phase":"learn","category":"pitfall","trigger":"entity|jpa|n+1","learning":"use @EntityGraph on findAll","evidence":"OrderRepo:20","confidence":0.86,"hits":5}
EOF
echo '{"category":"pitfall","trigger":"jpa, n+1, entity","learning":"use @EntityGraph on findAll","evidence":"OrderRepo:20","confidence":0.86}' > "$T/cand.jsonl"
R="$("$SH" --candidates "$T/cand.jsonl" --ts 2026-06-17T10:00:00Z)"
[ "$(jq -r '.promoted' <<<"$R")" = 1 ] && ok "report: 1 promoted" || bad "promoted report ($R)"
[ "$(jq -sc 'map(select(.id=="L-0001"))|.[0].promoted' "$(store)")" = true ] \
  && ok "L-0001 marked promoted=true" || bad "promoted flag not set"
grep -qF "Learned pitfalls (auto-promoted" "$T/.claude/rules/framework/jpa.md" \
  && grep -qF "use @EntityGraph on findAll" "$T/.claude/rules/framework/jpa.md" \
  && ok "rule file got promoted section + line" || bad "rule file not written"
# idempotency: re-run must NOT re-promote or duplicate the bullet
R2="$("$SH" --candidates "$T/cand.jsonl" --ts 2026-06-17T11:00:00Z)"
[ "$(jq -r '.promoted' <<<"$R2")" = 0 ] && ok "re-run: 0 promoted (idempotent)" || bad "re-promoted ($R2)"
[ "$(grep -c '^- ' "$T/.claude/rules/framework/jpa.md")" = 1 ] \
  && ok "re-run: rule file still 1 bullet (no dup)" || bad "rule bullet duplicated"
rm -rf "$T"

echo "== merge-learnings: quality gate + recurrence (v0.7, Issue 7) =="
new_proj
cat > "$(store)" <<'EOF'
{"id":"L-0001","ts":"2026-06-01T00:00:00Z","project":"x","phase":"learn","category":"pitfall","trigger":"jpa|n+1|orderrepository","learning":"OrderRepository.findAll triggers N+1 — use @EntityGraph","evidence":"OrderRepository.java:42","confidence":0.9,"hits":6,"promoted":true,"recurrence":0}
EOF
cat > "$T/cand.jsonl" <<'EOF'
{"category":"note","trigger":"jpa","learning":"be careful with jpa","evidence":"no evidence"}
{"category":"pitfall","trigger":"orderrepository, n+1, jpa","learning":"OrderRepository.findAll N+1 recurs — use @EntityGraph","evidence":"OrderRepository.java:42","confidence":0.7}
EOF
R="$("$SH" --candidates "$T/cand.jsonl" --ts 2026-06-29T00:00:00Z)"
[ "$(jq -r '.rejected' <<<"$R")" = 1 ] && ok "quality gate: vague no-evidence candidate rejected" || bad "quality gate ($R)"
[ "$(jq -r '.recurred' <<<"$R")" = 1 ] && ok "recurrence: promoted pitfall resurfaced counted" || bad "recurrence report ($R)"
[ "$(jq -sc 'map(select(.id=="L-0001"))|.[0].recurrence' "$(store)")" = 1 ] \
  && ok "recurrence: L-0001.recurrence 0->1" || bad "recurrence not bumped on entry"
[ -z "$(jq -sc 'map(select(.learning=="be careful with jpa"))|.[0]//empty' "$(store)")" ] \
  && ok "quality gate: vague candidate NOT written to store" || bad "vague candidate leaked into store"
rm -rf "$T"

echo "== merge-learnings: promotion edges (v0.7 — R7 hardening) =="
# Edge 1 — UNKNOWN trigger must NOT promote (never guess a rule file).
new_proj
cat > "$(store)" <<'EOF'
{"id":"L-0001","ts":"2026-06-01T00:00:00Z","project":"x","phase":"learn","category":"pitfall","trigger":"telemetry|widget|gizmo","learning":"do the widget thing","evidence":"W.java:1","confidence":0.86,"hits":5}
EOF
echo '{"category":"pitfall","trigger":"widget, gizmo, telemetry","learning":"do the widget thing","evidence":"W.java:1","confidence":0.86}' > "$T/cand.jsonl"
R="$("$SH" --candidates "$T/cand.jsonl" --ts 2026-06-29T00:00:00Z)"
[ "$(jq -r '.promoted' <<<"$R")" = 0 ] && ok "unknown trigger: promoted=0 (no rule-file guess)" || bad "unknown trigger promoted ($R)"
[ "$(jq -sc 'map(select(.id=="L-0001"))|.[0].promoted // false' "$(store)")" = "false" ] \
  && ok "unknown trigger: entry stays unpromoted" || bad "unknown trigger entry promoted wrongly"
rm -rf "$T"

# Edge 2 — threshold CROSSING on merge promotes (hits 4->5 AND conf 0.84->0.89).
new_proj
echo "# Redis rules" > "$T/.claude/rules/framework/redis.md"
cat > "$(store)" <<'EOF'
{"id":"L-0005","ts":"2026-06-01T00:00:00Z","project":"x","phase":"learn","category":"pitfall","trigger":"redis|cache|ttl","learning":"set a TTL on every @Cacheable","evidence":"C.java:9","confidence":0.84,"hits":4}
EOF
echo '{"category":"pitfall","trigger":"cache, redis, ttl","learning":"set a TTL on every @Cacheable","evidence":"C.java:9","confidence":0.84}' > "$T/cand.jsonl"
R="$("$SH" --candidates "$T/cand.jsonl" --ts 2026-06-29T00:00:00Z)"
[ "$(jq -r '.promoted' <<<"$R")" = 1 ] && ok "threshold crossing: promoted=1 (hits 4->5, conf 0.84->0.89)" || bad "threshold crossing not promoted ($R)"
grep -qF "set a TTL on every @Cacheable" "$T/.claude/rules/framework/redis.md" \
  && ok "threshold crossing: line routed to framework/redis.md" || bad "threshold crossing rule not written"
rm -rf "$T"

# Edge 3 — PRUNE must NOT drop a promoted entry even when it looks decayed (conf<0.25, hits<=1, old).
new_proj
cat > "$(store)" <<'EOF'
{"id":"L-0009","ts":"2020-01-01T00:00:00Z","project":"x","phase":"learn","category":"pitfall","trigger":"old|promoted","learning":"kept because promoted","evidence":"O.java:1","confidence":0.1,"hits":1,"promoted":true}
EOF
echo '{"category":"note","trigger":"unrelated, harmless","learning":"new unrelated note here","evidence":"N.java:2","confidence":0.6}' > "$T/cand.jsonl"
R="$("$SH" --candidates "$T/cand.jsonl" --ts 2026-06-29T00:00:00Z)"
[ -n "$(jq -sc 'map(select(.id=="L-0009"))|.[0]//empty' "$(store)")" ] \
  && ok "prune-protect: promoted L-0009 survives despite decay markers" || bad "prune dropped a promoted entry"
rm -rf "$T"

echo "== merge-learnings: fail-open / no-op guards =="
new_proj
R="$("$SH" --candidates "$T/does-not-exist.jsonl")"
[ "$(jq -r '.skipped' <<<"$R")" = "no-candidates" ] && ok "missing candidates file -> no-op skip" || bad "no-candidates guard ($R)"
[ ! -f "$(store)" ] && ok "no store created when nothing to merge" || bad "spurious store write"
rm -rf "$T"

echo
echo "MERGE-LEARNINGS: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
