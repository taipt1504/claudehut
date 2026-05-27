#!/usr/bin/env bash
# reuse-scan-grep.sh — fallback grep + heuristic candidate search
# Usage: reuse-scan-grep.sh "<topic>" [noun1 noun2 ...]
set -euo pipefail

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
cd "$PROJECT_ROOT"

TOPIC="${1:-}"
shift || true
NOUNS=("$@")

# If no explicit nouns, derive from topic
if [[ ${#NOUNS[@]} -eq 0 && -n "$TOPIC" ]]; then
  # Reuse extract-nouns.sh from brainstorm skill
  EXTRACT="${CLAUDE_PLUGIN_ROOT:-$(dirname "$(realpath "$0")")/../../..}/skills/brainstorm/scripts/extract-nouns.sh"
  if [[ -x "$EXTRACT" ]]; then
    read -ra NOUNS < <("$EXTRACT" "$TOPIC")
  fi
fi

[[ ${#NOUNS[@]} -gt 0 ]] || { echo "[]"; exit 0; }

# Search Java sources
RESULTS=()
for n in "${NOUNS[@]}"; do
  # Class names containing noun (case-insensitive)
  while IFS= read -r line; do
    file="${line%%:*}"
    [[ -z "$file" ]] && continue
    cls="$(basename "$file" .java)"
    # Recency
    mtime="$(stat -f '%m' "$file" 2>/dev/null || stat -c '%Y' "$file" 2>/dev/null || echo 0)"
    age_days=$(( ( $(date +%s) - mtime ) / 86400 ))
    recency=$(awk "BEGIN{printf \"%.3f\", exp(-$age_days/90)}")
    # Crude purpose: first /** ... */ line
    purpose=$(awk '/\/\*\*/,/\*\//{print}' "$file" 2>/dev/null | head -3 | tail -1 | sed 's|.*\*\s*||;s|\.$||' | head -1)
    [[ -z "$purpose" ]] && purpose="(no doc)"
    # Layer inference
    case "$cls" in
      *Controller) layer="Controller" ;;
      *Handler) layer="Handler" ;;
      *Service) layer="Service" ;;
      *Repository) layer="Repository" ;;
      *Mapper) layer="Mapper" ;;
      *Config|*Configuration) layer="Config" ;;
      *) layer="Unknown" ;;
    esac
    score=$(awk "BEGIN{printf \"%.3f\", 0.7 * (0.5 * 0.6 + 0.3 * $recency + 0.2 * 0.1)}")
    RESULTS+=("$(jq -n \
      --arg p "$file" --arg c "$cls" --arg pur "$purpose" \
      --arg src "grep" --arg lay "$layer" \
      --argjson sc "$score" '{
        path: $p, class: $c, purpose_one_line: $pur,
        score: $sc, source: $src, layer: $lay, cross_project: false
      }')")
  done < <(grep -rln --include="*.java" -i "class .*$n" src/main/java/ 2>/dev/null | head -5)
done

# Dedupe by path, keep top 5 by score
printf '%s\n' "${RESULTS[@]}" \
  | jq -s 'unique_by(.path) | sort_by(-.score) | .[0:5]'
