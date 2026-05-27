#!/usr/bin/env bash
# scripts/state/init-project.sh — scaffold .claudehut/ in current project +
# augment .claude/CLAUDE.md so native Claude Code is aware of plugin runtime state.
set -euo pipefail

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"

# Walk up from script location until we find the plugin marker.
# Works whether script is invoked from scripts/state/, skills/init/scripts/, or elsewhere.
_find_plugin_root() {
  if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" ]]; then echo "$CLAUDE_PLUGIN_ROOT"; return; fi
  local d
  d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
  while [[ "$d" != "/" && -n "$d" ]]; do
    [[ -f "$d/.claude-plugin/plugin.json" ]] && { echo "$d"; return; }
    d="$(dirname "$d")"
  done
  echo "error: cannot locate ClaudeHut plugin root (no .claude-plugin/plugin.json found upward)" >&2
  exit 1
}
PLUGIN_ROOT="$(_find_plugin_root)"

TARGET="$PROJECT_ROOT/.claudehut"

MODE="init"
if [[ -d "$TARGET" ]]; then
  MODE="repair"
  echo "claudehut: .claudehut/ already exists — running in REPAIR mode (re-creates missing files only, never overwrites existing)"
fi

# Scaffold runtime state directories (idempotent: mkdir -p)
mkdir -p \
  "$TARGET/memory" \
  "$TARGET/specs" \
  "$TARGET/plans" \
  "$TARGET/findings" \
  "$TARGET/reuse-scans" \
  "$TARGET/rules"

# Helper: copy only if missing
copy_if_missing() {
  local src="$1" dst="$2"
  if [[ ! -f "$dst" ]]; then
    cp "$src" "$dst"
    echo "claudehut: created $dst"
  fi
}

# Copy templates (only if missing — preserves user edits)
copy_if_missing "$PLUGIN_ROOT/templates/claudehut-config.template.json" "$TARGET/claudehut-config.json"
copy_if_missing "$PLUGIN_ROOT/templates/stack-signals.template.json"    "$TARGET/memory/stack-signals.json"
copy_if_missing "$PLUGIN_ROOT/templates/conventions.template.md"        "$TARGET/memory/conventions.md"
copy_if_missing "$PLUGIN_ROOT/templates/index.template.md"              "$TARGET/memory/index.md"

# Touch empty files (only if missing — preserves learnings)
[[ -f "$TARGET/memory/learnings.jsonl" ]] || : > "$TARGET/memory/learnings.jsonl"
[[ -f "$TARGET/memory/reusable-impl-map.json" ]] || : > "$TARGET/memory/reusable-impl-map.json"

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

# Safety: refresh backup of existing CLAUDE.md on every run so the latest user edits
# survive a disappear-restore cycle. If the file later vanishes (third-party hook /
# session cleanup), we restore from the most recent snapshot.
CLAUDE_BACKUP="$TARGET/.claude-md.backup"
if [[ -f "$CLAUDE_MD" ]]; then
  cp "$CLAUDE_MD" "$CLAUDE_BACKUP"
fi

if [[ -f "$CLAUDE_MD" ]]; then
  if grep -q "$CLAUDEHUT_SECTION_MARKER" "$CLAUDE_MD"; then
    echo "claudehut: section already present in $CLAUDE_MD; skipping augmentation"
  else
    echo "" >> "$CLAUDE_MD"
    echo "$CLAUDEHUT_BLOCK" >> "$CLAUDE_MD"
    echo "claudehut: appended section to existing $CLAUDE_MD"
  fi
elif [[ -f "$CLAUDE_BACKUP" ]]; then
  # File disappeared since first init (third-party hook/cleanup). Restore from backup
  # then re-augment if marker missing. Never lose user content.
  cp "$CLAUDE_BACKUP" "$CLAUDE_MD"
  if ! grep -q "$CLAUDEHUT_SECTION_MARKER" "$CLAUDE_MD"; then
    echo "" >> "$CLAUDE_MD"
    echo "$CLAUDEHUT_BLOCK" >> "$CLAUDE_MD"
  fi
  echo "claudehut: restored $CLAUDE_MD from .claudehut/.claude-md.backup (file had been removed)"
else
  # Truly fresh: write ONLY the marked section. No template heading — user owns
  # the rest of CLAUDE.md. If file later disappears, backup mechanism recovers.
  printf '%s\n' "$CLAUDEHUT_BLOCK" > "$CLAUDE_MD"
  cp "$CLAUDE_MD" "$CLAUDE_BACKUP"
  echo "claudehut: created $CLAUDE_MD with plugin section only (no template heading)"
fi

# === Initialize rules/ with README + active rules listing ===
RULES_README="$TARGET/rules/README.md"
RULES_LISTING="$TARGET/rules/active-rules.md"
mkdir -p "$TARGET/rules"

cat > "$RULES_README" <<'RULES_README_EOF'
# ClaudeHut Rules — Project-Local Overrides

Plugin ships 42 standard rules at `<plugin>/rules/` (loaded automatically by the
`PreToolUse` hook based on file pattern matches in `<plugin>/rules/rules-index.json`).

## Override mechanism

Drop a markdown file here to OVERRIDE a plugin rule:

```
.claudehut/rules/
├── coding/naming.md             ← overrides plugin's coding/naming
├── framework/spring-mvc.md      ← overrides plugin's framework/spring-mvc
└── company-style.md             ← project-specific (no plugin counterpart)
```

Precedence: project-local > plugin default.

## Add a project-specific rule

1. Create the file under appropriate category (`coding/`, `architecture/`, `testing/`,
   `security/`, `performance/`, `framework/`, or root).
2. Add a `rules-index.local.json` entry (if you want auto-load) — see
   `<plugin>/rules/rules-index.json` for format.
3. Commit. Team picks it up on next session.

## Active rule listing

See `active-rules.md` for the full list of rules currently auto-loaded from the
plugin. Update by re-running `/claudehut:init` after plugin upgrade.
RULES_README_EOF

# Generate active-rules.md from plugin's rules-index.json
PLUGIN_RULES_INDEX="$PLUGIN_ROOT/rules/rules-index.json"
if [[ -f "$PLUGIN_RULES_INDEX" ]]; then
  {
    echo "# Active Plugin Rules (auto-loaded by PreToolUse hook)"
    echo ""
    echo "Generated by \`/claudehut:init\` from plugin's \`rules/rules-index.json\`."
    echo "Re-run init to refresh after plugin upgrade."
    echo ""
    echo "Total: $(jq -r '. | length' "$PLUGIN_RULES_INDEX") index entries."
    echo ""
    echo "| Glob | Rule | Stack filter |"
    echo "|------|------|--------------|"
    jq -r '.[] | "| `\(.glob)` | `\(.rule)` | \(.if_stack // "any") |"' "$PLUGIN_RULES_INDEX"
  } > "$RULES_LISTING"
  echo "claudehut: wrote $RULES_LISTING ($(jq -r '. | length' "$PLUGIN_RULES_INDEX") rules indexed)"
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
if [[ "$MODE" == "repair" ]]; then
  echo "ClaudeHut REPAIR complete at: $TARGET"
else
  echo "ClaudeHut initialized at: $TARGET"
fi
echo ""
echo "Project layout:"
echo "  .claude/CLAUDE.md                  ← native Claude memory (plugin section appended)"
echo "  .claudehut/                        ← plugin runtime state (committed)"
echo "  .claudehut/.claude-md.backup       ← backup of CLAUDE.md (auto-restore on disappear)"
echo "  .claudehut/memory/                 ← conventions + learnings + stack signals"
echo "  .claudehut/rules/                  ← project-local rule overrides (README inside)"
echo "  .claudehut/{specs,plans,findings}/ ← per-task workflow artifacts"
echo ""
echo "Next steps:"
echo "  1. Review .claudehut/claudehut-config.json"
echo "  2. Verify .claudehut/memory/stack-signals.json reflects your stack"
echo "  3. Edit .claudehut/memory/conventions.md if your team differs from defaults"
echo "  4. Commit .claude/CLAUDE.md + .claudehut/ + .gitignore changes"
