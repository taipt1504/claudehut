#!/usr/bin/env bash
# scripts/state/init-project.sh — scaffold .claudehut/ in current project +
# augment .claude/CLAUDE.md so native Claude Code is aware of plugin runtime state.
set -euo pipefail

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(dirname "$(realpath "$0")")/../..}"
TARGET="$PROJECT_ROOT/.claudehut"

if [[ -d "$TARGET" ]]; then
  echo "ClaudeHut: .claudehut/ already exists at $TARGET" >&2
  exit 1
fi

# Scaffold runtime state directories
mkdir -p \
  "$TARGET/memory" \
  "$TARGET/specs" \
  "$TARGET/plans" \
  "$TARGET/findings" \
  "$TARGET/reuse-scans" \
  "$TARGET/rules"

# Copy templates
cp "$PLUGIN_ROOT/templates/claudehut-config.template.json" "$TARGET/claudehut-config.json"
cp "$PLUGIN_ROOT/templates/stack-signals.template.json"    "$TARGET/memory/stack-signals.json"
cp "$PLUGIN_ROOT/templates/conventions.template.md"        "$TARGET/memory/conventions.md"
cp "$PLUGIN_ROOT/templates/index.template.md"              "$TARGET/memory/index.md"

# Touch empty files
: > "$TARGET/memory/learnings.jsonl"
: > "$TARGET/memory/reusable-impl-map.json"

# === Augment .claude/CLAUDE.md (defense-in-depth: native Claude awareness) ===
CLAUDE_DIR="$PROJECT_ROOT/.claude"
CLAUDE_MD="$CLAUDE_DIR/CLAUDE.md"
mkdir -p "$CLAUDE_DIR"

CLAUDEHUT_SECTION_MARKER="<!-- claudehut-managed-section -->"
CLAUDEHUT_END_MARKER="<!-- /claudehut-managed-section -->"
CLAUDEHUT_BLOCK="$CLAUDEHUT_SECTION_MARKER
## ClaudeHut Plugin Active

This project uses the ClaudeHut plugin for agentic Java backend workflows.

**Runtime state** (managed by plugin, do not hand-edit during a task):
- \`.claudehut/memory/conventions.md\` — project conventions
- \`.claudehut/memory/index.md\` — reusable impl map for reuse-scan
- \`.claudehut/memory/stack-signals.json\` — detected stack (web/orm/db/mapper/serialization)
- \`.claudehut/specs/<task>-design.md\` — Phase 1 artifact
- \`.claudehut/specs/<task>-contract.md\` — Phase 2 artifact
- \`.claudehut/plans/<task>-plan.md\` — Phase 3 artifact
- \`.claudehut/findings/<task>-findings.json\` — Phase 5 artifact
- \`.claudehut/memory/learnings.jsonl\` — append-only learnings

**Workflow (6-phase, enforced via hooks)**:
Brainstorm → Spec → Plan → Build → Loop (verify/review/refactor) → Learn

**Hard rules**:
- Phase derives from artifacts present + git branch. Do not bypass.
- Source edits (\`src/\`) only allowed in Build phase.
- New Java files require fresh reuse-scan (< 10 min).
- TDD enforced: failing test before production code, watch-test-fail.
- One commit per plan task. Commit message \`refactor(loop):\` for loop iterations.

Plugin docs: see plugin root \`agents/\`, \`skills/\`, \`rules/\` directories.
$CLAUDEHUT_END_MARKER"

if [[ -f "$CLAUDE_MD" ]]; then
  if grep -q "$CLAUDEHUT_SECTION_MARKER" "$CLAUDE_MD"; then
    echo "claudehut: section already present in $CLAUDE_MD; skipping augmentation" >&2
  else
    echo "" >> "$CLAUDE_MD"
    echo "$CLAUDEHUT_BLOCK" >> "$CLAUDE_MD"
    echo "claudehut: appended section to existing $CLAUDE_MD"
  fi
else
  cat > "$CLAUDE_MD" <<EOF
# Project Memory (Claude Code)

$CLAUDEHUT_BLOCK
EOF
  echo "claudehut: created $CLAUDE_MD with plugin section"
fi

# === .gitignore patches ===
GI="$PROJECT_ROOT/.gitignore"
if [[ ! -f "$GI" ]]; then
  touch "$GI"
fi
if ! grep -q "^.claudehut/reuse-scans/" "$GI" 2>/dev/null; then
  cat >> "$GI" <<'EOF'

# ClaudeHut plugin — runtime ephemeral files
.claudehut/reuse-scans/
.claudehut/findings/*.tmp
.claudehut/.tmp/
EOF
  echo "claudehut: appended .gitignore patches"
fi

echo ""
echo "ClaudeHut initialized at: $TARGET"
echo ""
echo "Project layout:"
echo "  .claude/CLAUDE.md          ← native Claude memory (now hints ClaudeHut)"
echo "  .claudehut/                ← plugin runtime state (committed)"
echo "  .claudehut/memory/         ← conventions + learnings + stack signals"
echo "  .claudehut/{specs,plans,findings}/ ← per-task workflow artifacts"
echo ""
echo "Next steps:"
echo "  1. Review .claudehut/claudehut-config.json"
echo "  2. Verify .claudehut/memory/stack-signals.json reflects your stack"
echo "  3. Edit .claudehut/memory/conventions.md if your team differs from defaults"
echo "  4. Commit .claude/CLAUDE.md + .claudehut/ + .gitignore changes"
