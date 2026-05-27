#!/usr/bin/env bash
# validate-skill.sh — check a skill conforms to 3-bucket pattern
set -euo pipefail

SKILL="${1:-}"
[[ -d "$SKILL" ]] || { echo "error: skill dir not found: $SKILL" >&2; exit 2; }

issues=0
SKILL_MD="$SKILL/SKILL.md"

if [[ ! -f "$SKILL_MD" ]]; then
  echo "❌ Missing SKILL.md" >&2
  exit 1
fi

# Frontmatter check
if ! head -1 "$SKILL_MD" | grep -q '^---$'; then
  echo "❌ SKILL.md must start with YAML frontmatter (---)" >&2
  issues=$((issues + 1))
fi

NAME="$(awk '/^---$/{c++; next} c==1 && /^name:/{print $2; exit}' "$SKILL_MD")"
DESC="$(awk '/^---$/{c++; next} c==1 && /^description:/{sub(/^description:[ \t]*/, ""); print; exit}' "$SKILL_MD")"

if [[ -z "$NAME" ]]; then
  echo "❌ Missing 'name' in frontmatter" >&2
  issues=$((issues + 1))
fi
if [[ -z "$DESC" ]]; then
  echo "❌ Missing 'description' in frontmatter" >&2
  issues=$((issues + 1))
fi

FOLDER="$(basename "$SKILL")"
if [[ -n "$NAME" && "$NAME" != "$FOLDER" ]]; then
  echo "❌ Frontmatter name '$NAME' must match folder name '$FOLDER'" >&2
  issues=$((issues + 1))
fi

if [[ -n "$DESC" && ${#DESC} -gt 500 ]]; then
  echo "⚠️  description is ${#DESC} chars — recommend ≤ 200" >&2
fi

# Length budget
LINES="$(wc -l < "$SKILL_MD")"
if [[ "$LINES" -gt 500 ]]; then
  echo "❌ SKILL.md is $LINES lines, exceeds 500 hard limit" >&2
  issues=$((issues + 1))
elif [[ "$LINES" -gt 300 ]]; then
  echo "⚠️  SKILL.md is $LINES lines, target ≤ 300 (split into references/)" >&2
fi

# 3-bucket presence
for d in references scripts; do
  [[ -d "$SKILL/$d" ]] || echo "⚠️  Missing optional dir: $d/" >&2
done

# Forbidden files
for f in README.md INSTALL.md CHANGELOG.md NOTES.md; do
  if [[ -f "$SKILL/$f" ]]; then
    echo "❌ Forbidden file in skill folder: $f" >&2
    issues=$((issues + 1))
  fi
done

# References length + TOC check
if [[ -d "$SKILL/references" ]]; then
  for ref in "$SKILL/references"/*.md; do
    [[ -f "$ref" ]] || continue
    rlines="$(wc -l < "$ref")"
    if [[ "$rlines" -gt 100 ]] && ! grep -q "## Table of contents" "$ref"; then
      echo "⚠️  $(basename "$ref") is $rlines lines but lacks TOC" >&2
    fi
    if [[ "$rlines" -gt 500 ]]; then
      echo "⚠️  $(basename "$ref") is $rlines lines — consider splitting" >&2
    fi
  done
fi

if [[ $issues -gt 0 ]]; then
  echo "Skill validation: $issues issue(s)" >&2
  exit 1
fi
echo "Skill validation: clean ($NAME)"
exit 0
