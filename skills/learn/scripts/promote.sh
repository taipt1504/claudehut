#!/usr/bin/env bash
# promote.sh — promote a learning entry to global tier if threshold met
set -euo pipefail

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
GLOBAL_DIR="${HOME}/.claude/claudehut/memory"
GLOBAL_PATTERNS="$GLOBAL_DIR/patterns.jsonl"
GLOBAL_PROJECTS="$GLOBAL_DIR/projects.json"
LEARNINGS="$PROJECT_ROOT/.claudehut/memory/learnings.jsonl"
CONFIG="$PROJECT_ROOT/.claudehut/claudehut-config.json"

mkdir -p "$GLOBAL_DIR"
[[ -f "$LEARNINGS" ]] || { echo "no learnings to promote"; exit 0; }
[[ -f "$GLOBAL_PROJECTS" ]] || echo '{}' > "$GLOBAL_PROJECTS"
[[ -f "$GLOBAL_PATTERNS" ]] || : > "$GLOBAL_PATTERNS"

OPT_IN="$(jq -r '.memory.global_promotion_opt_in // false' "$CONFIG" 2>/dev/null || echo false)"
if [[ "$OPT_IN" != "true" ]]; then
  echo "promote: global_promotion_opt_in=false, skipping"
  exit 0
fi

THRESHOLD="$(jq -r '.memory.promotion_min_projects // 3' "$CONFIG" 2>/dev/null || echo 3)"

# Project identity
REMOTE_URL="$(git -C "$PROJECT_ROOT" config --get remote.origin.url 2>/dev/null || git -C "$PROJECT_ROOT" rev-parse --show-toplevel)"
PROJECT_HASH="$(echo -n "$REMOTE_URL" | shasum -a 256 | cut -d' ' -f1)"

# For each entry in this session's learnings, update projects.json and check threshold
promoted=0
while IFS= read -r entry; do
  sig="$(echo "$entry" | jq -r '.signature // empty')"
  [[ -z "$sig" ]] && continue

  # Update projects.json
  jq --arg sig "$sig" --arg p "$PROJECT_HASH" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    if (.[$sig]) then
      .[$sig].projects = ((.[$sig].projects + [$p]) | unique)
      | .[$sig].last_seen = $ts
      | .[$sig].hits = (.[$sig].hits // 0) + 1
    else
      .[$sig] = {projects: [$p], first_seen: $ts, last_seen: $ts, hits: 1}
    end
  ' "$GLOBAL_PROJECTS" > "${GLOBAL_PROJECTS}.tmp" && mv "${GLOBAL_PROJECTS}.tmp" "$GLOBAL_PROJECTS"

  # Check threshold
  count="$(jq -r --arg sig "$sig" '.[$sig].projects | length' "$GLOBAL_PROJECTS")"
  if (( count >= THRESHOLD )); then
    # Check noPromote flag
    no_promote="$(echo "$entry" | jq -r '.noPromote // false')"
    [[ "$no_promote" == "true" ]] && continue

    # Check not already promoted
    if ! grep -q "\"signature\": *\"$sig\"" "$GLOBAL_PATTERNS" 2>/dev/null; then
      echo "$entry" | jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson count "$count" '
        del(.files_touched)
        | .promoted_at = $ts
        | .projects_count = $count
      ' >> "$GLOBAL_PATTERNS"
      promoted=$((promoted + 1))
    fi
  fi
done < "$LEARNINGS"

echo "promote: $promoted entries promoted to global"
