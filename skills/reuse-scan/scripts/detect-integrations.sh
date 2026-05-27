#!/usr/bin/env bash
# detect-integrations.sh — populate state/integrations.json
set -euo pipefail

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
STATE_DIR="$PROJECT_ROOT/.claudehut/state"
mkdir -p "$STATE_DIR"

ua_avail=false
ua_path=""
if [[ -f "$PROJECT_ROOT/.understand-anything/knowledge-graph.json" ]]; then
  ua_avail=true
  ua_path=".understand-anything/knowledge-graph.json"
fi

graphify_avail=false
graphify_path=""
graphify_global=false
if command -v graphify >/dev/null 2>&1; then
  graphify_avail=true
  if graphify global list >/dev/null 2>&1; then
    graphify_global=true
  fi
fi
if [[ -f "$PROJECT_ROOT/graphify-out/graph.json" ]]; then
  graphify_path="graphify-out/graph.json"
fi

jq -n \
  --argjson ua "$ua_avail" \
  --arg ua_p "$ua_path" \
  --argjson gf "$graphify_avail" \
  --arg gf_p "$graphify_path" \
  --argjson gfg "$graphify_global" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{
    understand_anything: {available: $ua, graph_path: $ua_p},
    graphify: {available: $gf, graph_path: $gf_p, global_registry: $gfg},
    detected_at: $ts
  }' > "$STATE_DIR/integrations.json"

cat "$STATE_DIR/integrations.json"
