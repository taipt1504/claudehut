#!/usr/bin/env bash
# SessionStart hook (matcher: startup|clear|compact).
# Injects the claudehut-workflow orchestrator + top learnings + understand-anything
# detection flag as additionalContext, before turn 1. Emits a top-level systemMessage
# (user-visible) when the codebase index is absent. Never blocks (SessionStart cannot block). See 06 §3.
set -euo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
DIR="$PROJECT_DIR/.claude/claudehut"
in="$(cat 2>/dev/null || true)"   # SessionStart hook payload (carries session_id)

command -v jq >/dev/null 2>&1 || { echo '{}'; exit 0; }   # degrade: no context injection without jq

# opt #3 FALLBACK — INVOCATION reliability. The init skill's !`...` script call is flaky in headless
# (P7 measured 2/3: skill engaged but the script didn't always run). So bootstrap the plane
# DETERMINISTICALLY here, with zero model reliance: if .claude/claudehut/ is absent, run the generator
# directly (stdout suppressed so it can't corrupt this hook's JSON). The skill remains for --refresh + enrich.
WAS_ABSENT=false; [ -d "$DIR" ] || WAS_ABSENT=true
INITED=false
if $WAS_ABSENT && [ -x "$PLUGIN_ROOT/bin/claudehut-init" ]; then
  CLAUDE_PROJECT_DIR="$PROJECT_DIR" "$PLUGIN_ROOT/bin/claudehut-init" "$PROJECT_DIR" >/dev/null 2>&1 && INITED=true || true
fi

# opt #1 — ARM the write gate from turn 1. Create an initial per-session state file
# (phase=discover, reuse_scan=false) if none exists, so gate-write.sh denies production writes
# until the workflow produces reuse-scan + spec + plan. Without this the gate fails open on missing
# state and the workflow is effectively optional. gate-done.sh only enforces COMPLETION once the
# workflow is engaged, so this does not wedge non-coding sessions. Bypass: claudehut-state set-bypass true.
sid="$(jq -r '.session_id // empty' <<<"$in" 2>/dev/null || true)"
# Issue-1 durability: a compact/resume keeps the same session_id, so the live state file (and the
# implement_skill_ok skill-rail proof in it) normally survives untouched. If the live file is GONE
# (crash, manual cleanup), restore the PreCompact snapshot rather than re-arming from scratch —
# re-arming would reset phase to discover and close the skill rail mid-task (one wasted deny).
if [ -n "$sid" ] && [ ! -f "$DIR/state/$sid.json" ] && [ -f "$DIR/state/$sid.snapshot.json" ]; then
  mkdir -p "$DIR/state" 2>/dev/null || true
  cp -f "$DIR/state/$sid.snapshot.json" "$DIR/state/$sid.json" 2>/dev/null || true
fi
if [ -n "$sid" ] && [ ! -f "$DIR/state/$sid.json" ] && [ -x "$PLUGIN_ROOT/bin/claudehut-state" ]; then
  # Arm at phase=discover — phase 1 since the v0.4 Discover split (06 §3, 11 §5); also resets the skill rail.
  CLAUDE_PROJECT_DIR="$PROJECT_DIR" "$PLUGIN_ROOT/bin/claudehut-state" --session "$sid" set-phase discover >/dev/null 2>&1 || true
fi

# Rule-template migration (Issue 4): upgraded/new rule templates must reach EXISTING projects, not only
# fresh inits. Stamp the plugin version into the plane; on mismatch re-emit the rule tree only
# (claudehut-init --refresh-rules — never touches MEMORY/PROJECT/LANGUAGE, which users may have edited).
PV="$(jq -r '.version // empty' "$PLUGIN_ROOT/.claude-plugin/plugin.json" 2>/dev/null || true)"
if [ -n "$PV" ] && [ -d "$DIR" ] && [ -x "$PLUGIN_ROOT/bin/claudehut-init" ]; then
  STAMP="$DIR/.plugin-version"
  if [ "$(cat "$STAMP" 2>/dev/null || true)" != "$PV" ]; then
    CLAUDE_PROJECT_DIR="$PROJECT_DIR" "$PLUGIN_ROOT/bin/claudehut-init" "$PROJECT_DIR" --refresh-rules >/dev/null 2>&1 \
      && printf '%s' "$PV" > "$STAMP" 2>/dev/null || true
  fi
fi

ctx="$(cat "$PLUGIN_ROOT/skills/claudehut-workflow/SKILL.md" 2>/dev/null || echo "ClaudeHut workflow orchestrator skill not found.")"

# Top learnings (P7 helper — optional; no-op until present). WS-6: --snapshot records the injected IDs so the
# Learn phase can stamp .applied on the ones that resurface (closing the inject→use reinforcement loop).
if [ -x "$PLUGIN_ROOT/scripts/inject-learnings.sh" ] && [ -f "$DIR/learnings.jsonl" ]; then
  snap=""; [ -n "$sid" ] && { mkdir -p "$DIR/state" 2>/dev/null || true; snap="$DIR/state/$sid.injected.json"; }
  learn="$("$PLUGIN_ROOT/scripts/inject-learnings.sh" --top 12 ${snap:+--snapshot "$snap"} 2>/dev/null || true)"
  [ -n "$learn" ] && ctx="$ctx"$'\n\n## Learnings for this project (top by confidence x recency x hits)\n'"$learn"
fi

# understand-anything detection — no native runtime cross-plugin field exists, so read
# enabledPlugins via the CLI. Default to "absent" when the command/data is unavailable.
if command -v claude >/dev/null 2>&1 \
   && claude plugin list --json 2>/dev/null | jq -e '.[]? | select((.id | startswith("understand-anything@")) and (.enabled // false))' >/dev/null 2>&1; then
  ctx="$ctx"$'\n\n## understand-anything: ENABLED — Discover MUST use its query/search skills.'
else
  ctx="$ctx"$'\n\n## understand-anything: absent — Discover uses claudehut-explorer + Grep.'
fi

need_init=false
{ $WAS_ABSENT && ! $INITED; } && need_init=true   # only prompt if absent AND the deterministic fallback couldn't run

jq -n --arg ctx "$ctx" --arg dir "$DIR" --argjson need "$need_init" '
  {hookSpecificOutput: {hookEventName:"SessionStart", additionalContext:$ctx, watchPaths:[$dir], reloadSkills:true}}
  + (if $need
     then {systemMessage:"ClaudeHut: no codebase index found. Run /claudehut:init to bootstrap this project before starting a task."}
     else {} end)'
