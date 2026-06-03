#!/usr/bin/env bash
# T1 ranker eval for ClaudeHut's CURRENT learnings ranker (scripts/inject-learnings.sh).
# (The HEAD evals/retrieval/ suite targets the OLD plugin's skills/learn/scripts/retrieve-relevant.sh
#  + .claudehut/memory/ and is NOT runnable against this build — this is its adapted replacement.)
# Measures P5 read-path: relevance filter must beat recency/confidence, recency must order ties,
# and --top must cap output. No Claude, free, deterministic. Run: evals/ranker-tests.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INJ="$ROOT/scripts/inject-learnings.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; }

command -v jq >/dev/null 2>&1 || { echo "jq required"; exit 2; }
TMP="$(mktemp -d)"; export CLAUDE_PROJECT_DIR="$TMP"
mkdir -p "$TMP/.claude/claudehut"
# Corpus: 2 RELEVANT (jpa*, OLDER ts) + 2 DISTRACTORS (off-topic, NEWER ts + higher conf/hits).
# If recency/confidence won, distractors would dominate; the relevance filter must exclude them.
cat > "$TMP/.claude/claudehut/learnings.jsonl" <<'EOF'
{"category":"pattern","trigger":"jpa entity fetch","learning":"prefer EntityGraph EGRAPHMARK","evidence":"OrderRepo.java:20","confidence":0.9,"hits":5,"ts":"2026-01-15T00:00:00Z"}
{"category":"pattern","trigger":"jpa repository","learning":"use BatchSize BSIZEMARK","evidence":"X.java:1","confidence":0.8,"hits":3,"ts":"2025-12-01T00:00:00Z"}
{"category":"pattern","trigger":"kafka consumer","learning":"manual ack KAFKAMARK","evidence":"Y.java:2","confidence":0.9,"hits":9,"ts":"2026-05-01T00:00:00Z"}
{"category":"pattern","trigger":"redis cache","learning":"ttl required REDISMARK","evidence":"Z.java:3","confidence":0.95,"hits":10,"ts":"2026-06-01T00:00:00Z"}
EOF

echo "== P5 ranker (current inject-learnings.sh) =="

# A — relevance filter precision: matches surface, off-topic newer/higher entries excluded
A="$(bash "$INJ" --filter "jpa entity fetch" --top 12)"
{ grep -q EGRAPHMARK <<<"$A" && grep -q BSIZEMARK <<<"$A"; } && ok "filter returns both relevant entries (recall)" || bad "filter missed a relevant entry"
{ ! grep -q KAFKAMARK <<<"$A" && ! grep -q REDISMARK <<<"$A"; } && ok "filter excludes newer/higher-conf distractors (relevance > recency)" || bad "distractor leaked through filter"

# B — recency orders the matched set (R1 newer than R2 → ranks first)
posE=$(grep -n EGRAPHMARK <<<"$A" | head -1 | cut -d: -f1)
posB=$(grep -n BSIZEMARK  <<<"$A" | head -1 | cut -d: -f1)
[ -n "$posE" ] && [ -n "$posB" ] && [ "$posE" -lt "$posB" ] && ok "recency×conf×hits orders matches (newer first)" || bad "ordering wrong (E=$posE B=$posB)"

# C — --top caps output
C="$(bash "$INJ" --filter "jpa entity fetch" --top 1)"
[ "$(grep -c EGRAPHMARK <<<"$C")" = "1" ] && [ "$(grep -c BSIZEMARK <<<"$C")" = "0" ] && ok "--top 1 caps to the single top entry" || bad "--top cap not honored"

# D — no filter: recency/score ranking dominates (newest distractor tops)
D="$(bash "$INJ" --top 2)"
grep -q REDISMARK <<<"$D" && ok "unfiltered: newest/highest-score entry surfaces (recency real)" || bad "unfiltered ranking not by score"

rm -rf "$TMP"
echo
echo "RANKER: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
