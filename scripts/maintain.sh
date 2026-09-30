#!/usr/bin/env bash
# SessionStart hook, ASYNC (matcher: startup) — plane maintenance moved out of the sync bootstrap (05 §5,
# ADR-H8). Takes effect in a later turn or session. An async hook has no timeout and is killed under `-p`,
# so every step is idempotent and records its marker (.plugin-version) only after the step succeeded.
#
#   1. rules: re-emit .claude/rules when .plugin-version differs from the plugin; report drift as systemMessage
#   2. Summer KB: zero-touch install for a Summer consumer, self-heal when the bundle's summerCommit moved
#   3. sweep: session sidecars and v0.11 state files older than 7 days (never the current session's)
#   4. hook-errors.log: keep the newest 32 KB once it passes 64 KB
# Not here yet: MEMORY.md migration and `claudehut-index update` (M5).

case "$0" in */*) _d="${0%/*}" ;; *) _d="." ;; esac
. "$_d/lib/hook-common.sh" 2>/dev/null || exit 0
hc_init
hc_plane_or_exit
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$_d/.." 2>/dev/null && pwd)}"

# 1. rule refresh + drift report
PV="$(jq -r '.version // empty' "$PLUGIN_ROOT/.claude-plugin/plugin.json" 2>/dev/null)" || PV=""
if [ -n "$PV" ] && [ -x "$PLUGIN_ROOT/bin/claudehut-init" ] \
   && [ "$(cat "$PLANE/.plugin-version" 2>/dev/null)" != "$PV" ]; then
  if CLAUDE_PROJECT_DIR="$PROJECT_DIR" "$PLUGIN_ROOT/bin/claudehut-init" "$PROJECT_DIR" --refresh-rules >/dev/null 2>&1; then
    printf '%s' "$PV" > "$PLANE/.plugin-version" || true
  fi
  drift="$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" "$PLUGIN_ROOT/bin/claudehut-init" "$PROJECT_DIR" --audit 2>/dev/null \
           | grep -m1 '^  summary:' | sed 's/^  summary: //')" || drift=""
  case "$drift" in
    ""|"0 stale, 0 missing, 0 over-budget memory file(s)") : ;;
    *) hc_sysmsg "ClaudeHut: rule drift after the plugin upgrade — $drift. Review with claudehut-init --audit." ;;
  esac
fi

# 2. Summer KB install / self-heal
KB_META="$PROJECT_DIR/.claude/summer-kb/.summer-kb-meta.json"
KB_INSTALL="$PLUGIN_ROOT/skills/summer-kb-setup/scripts/install_summer_kb.py"
KB_BUNDLE_META="$PLUGIN_ROOT/skills/summer-kb-setup/references/summer-kb/.bundle-meta.json"
if command -v python3 >/dev/null 2>&1 && [ -f "$KB_INSTALL" ]; then
  # -exec, not `| xargs`: a project path with a space must not split. Captured, not tested in a pipeline: with
  # pipefail an early-exiting `head` would make a real match read as a miss.
  kb_hit=""
  [ -f "$KB_META" ] || kb_hit="$(find "$PROJECT_DIR" -maxdepth 3 -name '*.gradle*' -not -path '*/build/*' \
      -exec grep -l 'io\.f8a\.summer:' {} + 2>/dev/null | head -1)" || kb_hit=""
  if [ -n "$kb_hit" ]; then
    python3 "$KB_INSTALL" "$PROJECT_DIR" >/dev/null 2>&1 || hc_log "summer-kb install failed"
  fi
  if [ -f "$KB_META" ] && [ -f "$KB_BUNDLE_META" ]; then
    inst="$(jq -r '.summerCommit // empty' "$KB_META" 2>/dev/null)" || inst=""
    bund="$(jq -r '.summerCommit // empty' "$KB_BUNDLE_META" 2>/dev/null)" || bund=""
    if [ -n "$inst" ] && [ -n "$bund" ] && [ "$inst" != "$bund" ]; then
      python3 "$KB_INSTALL" "$PROJECT_DIR" >/dev/null 2>&1 || hc_log "summer-kb self-heal failed"
    fi
  fi
fi

# 3. sweep (ST-1). Durable stores (learnings.jsonl, reuse-index.json, MEMORY*, ledger/, tasks/) live outside
#    state/ and are never touched. Sidecars older than 7 days go, except the current session's and the suspects
#    of a still-active task (<task-id>.suspects.jsonl). A pointer state/<sid>.json goes only when it no longer
#    names an active task (v0.11 / corrupt file, active_task null, closed or missing task): the set-* verbs
#    rewrite task.json, not the pointer, so its mtime says nothing about whether the task is still open.
task_active() { # $1 task id
  hc_safe_id "$1" || return 1
  jq -e 'type=="object" and .schema==2 and ((.status // "active")=="active")' "$PLANE/tasks/$1/task.json" >/dev/null 2>&1
}
while IFS= read -r -d '' f; do
  b="${f##*/}"
  case "$b" in
    "${HC_SID:-__none__}".*) continue ;;
    *.suspects.jsonl) task_active "${b%.suspects.jsonl}" && continue ;;
    *.*.json|*.jsonl|*.injected-phase|*.ua-flag|*.nudged|*.nudged.*) : ;;
    *.json)   # a pointer
      t="$(jq -r 'if type=="object" and .schema==2 then (.active_task // empty) else empty end' "$f" 2>/dev/null)" || t=""
      [ -n "$t" ] && task_active "$t" && continue ;;
    *) continue ;;
  esac
  rm -f "$f" 2>/dev/null || :
done < <(find "$PLANE/state" -maxdepth 1 -type f -mtime +7 -print0 2>/dev/null)

# 4. rotate the hook error log
LOG="$PLANE/state/hook-errors.log"
if [ -f "$LOG" ] && [ "$(wc -c < "$LOG" | tr -d ' ')" -gt 65536 ]; then
  tail -c 32768 "$LOG" > "$LOG.tmp" && mv -f "$LOG.tmp" "$LOG" || true
fi
exit 0
