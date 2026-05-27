#!/usr/bin/env bash
# init-skill.sh — scaffold a new ClaudeHut skill
set -euo pipefail

NAME="${1:-}"
DESC="${2:-}"
[[ -z "$NAME" ]] && { echo "usage: init-skill.sh <skill-name> '<description>'" >&2; exit 2; }

# Validate name kebab-case
if ! [[ "$NAME" =~ ^[a-z][a-z0-9-]*$ ]]; then
  echo "error: skill name must be lowercase kebab-case (got '$NAME')" >&2
  exit 1
fi

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(dirname "$(realpath "$0")")/../../..}"
TARGET="$PLUGIN_ROOT/skills/$NAME"

if [[ -d "$TARGET" ]]; then
  echo "error: $TARGET already exists" >&2
  exit 1
fi

mkdir -p "$TARGET/references" "$TARGET/scripts" "$TARGET/assets/templates"

cat > "$TARGET/SKILL.md" <<EOF
---
name: $NAME
description: $DESC
---

# $NAME

<one-sentence intent>

## Quick start

1. <step>
2. <step>

## Workflow

For details, load reference as needed:
- <topic> → \`references/<file>.md\`

## Scripts

- \`scripts/<action>.sh\` — <purpose>

## Assets

- \`assets/templates/<file>.tmpl\` — <when to materialize>

## Hard rules

- <constraint>

## Exit criteria

- [ ] <criterion>
EOF

touch "$TARGET/references/.gitkeep" "$TARGET/scripts/.gitkeep" "$TARGET/assets/templates/.gitkeep"

echo "Scaffolded: $TARGET"
echo "Next: edit SKILL.md, add references/scripts/assets as needed, run validate-skill.sh"
