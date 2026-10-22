#!/usr/bin/env bash
# SessionStart hook, ASYNC (matcher: startup) — plane maintenance moved out of the sync bootstrap (05 §5,
# ADR-H8). Takes effect in a later turn or session. An async hook has no timeout and is killed under `-p`,
# so every step is idempotent and records its marker (.plugin-version) only after the step succeeded.
#
#   1. rules: re-emit .claude/rules when .plugin-version differs from the plugin; report drift as systemMessage
#   2. Summer KB: zero-touch install for a Summer consumer; a stale stamp (summerCommit vs the Summer source repo's HEAD or the
#      bundle, or a newer build file) starts a detached refresh
#   3. sweep: session sidecars and v0.11 state files older than 7 days (never the current session's)
#   4. hook-errors.log: keep the newest 32 KB once it passes 64 KB
#   5. memory + index (07 §7, §8.1; initialized plane only): `claudehut-index memory` migrates a v0.11
#      MEMORY.md once (learner/template blocks → MEMORY-history.md) and regenerates the ≤2 KB generated part;
#      `claudehut-index update --detach` catches the index up with HEAD (no-op when fresh). Detached, because
#      an async hook is killed under -p.
# Rules refresh on a bare plane (no PROJECT.md) touches only .claude/rules: claudehut-init enforces that. A bare
# plane gets no .plugin-version and no Summer KB either (steps 1-2), so the refresh re-runs each startup until init.

case "$0" in */*) _d="${0%/*}" ;; *) _d="." ;; esac
. "$_d/lib/hook-common.sh" 2>/dev/null || exit 0
hc_init
hc_plane_or_exit
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$_d/.." 2>/dev/null && pwd)}"

# 1. rule refresh + drift report
PV="$(jq -r '.version // empty' "$PLUGIN_ROOT/.claude-plugin/plugin.json" 2>/dev/null)" || PV=""
if [ -n "$PV" ] && [ -x "$PLUGIN_ROOT/bin/claudehut-init" ] \
   && [ "$(cat "$PLANE/.plugin-version" 2>/dev/null)" != "$PV" ]; then
  # The marker only on an initialized plane: a bare plane (no PROJECT.md) gets no plugin-owned files.
  if CLAUDE_PROJECT_DIR="$PROJECT_DIR" "$PLUGIN_ROOT/bin/claudehut-init" "$PROJECT_DIR" --refresh-rules >/dev/null 2>&1 \
     && hc_plane_initialized; then
    printf '%s' "$PV" > "$PLANE/.plugin-version" || true
  fi
  drift="$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" "$PLUGIN_ROOT/bin/claudehut-init" "$PROJECT_DIR" --audit 2>/dev/null \
           | grep -m1 '^  summary:' | sed 's/^  summary: //')" || drift=""
  case "$drift" in
    ""|"0 stale, 0 missing, 0 over-budget memory file(s)") : ;;
    *) hc_sysmsg "ClaudeHut: rule drift after the plugin upgrade — $drift. Review with claudehut-init --audit." ;;
  esac
fi

# 2. Summer KB (pack org-summer, docs/v0.20 07 §2): its own script, so the org-summer plugin of the split
#    distribution runs the same code from its SessionStart hook. Absent (a distribution without org-summer) → skip.
KB_MAINT="$PLUGIN_ROOT/skills/summer-kb-setup/scripts/kb-maintain.sh"
if hc_plane_initialized && [ -f "$KB_MAINT" ]; then
  PROJECT_DIR="$PROJECT_DIR" PLANE="$PLANE" bash "$KB_MAINT" || hc_log "summer-kb maintenance failed"
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
    *.*.json|*.jsonl|*.injected-phase|*.ua-flag|*.nudged|*.nudged.*|index-head.*|index-build.pending) : ;;
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

# 5. memory + index
IDX_CLI="$PLUGIN_ROOT/bin/claudehut-index"
if hc_plane_initialized && [ -x "$IDX_CLI" ]; then
  ( cd "$PROJECT_DIR" && "$IDX_CLI" memory --plane "$PLANE" ) </dev/null >/dev/null 2>&1 || hc_log "claudehut-index memory failed"
  if [ -d "$PROJECT_DIR/.git" ]; then   # the index is stamped with a commit; a secondary worktree is skipped
    ( cd "$PROJECT_DIR" && exec "$IDX_CLI" update --detach --plane "$PLANE" ) </dev/null >/dev/null 2>&1 || hc_log "claudehut-index update failed"
  fi
fi

# 6. host probe (0.12.7, docs/v0.20 04 §5.1): test foreign Bash hooks for input rewriting under a 2 s deadline and
#    write state/env-profile.json; bootstrap.sh reads it next session (--cached). Off with CLAUDEHUT_HOST_PROBE=0.
KCLI="$PLUGIN_ROOT/bin/claudehut-kernel"
if [ "${CLAUDEHUT_HOST_PROBE:-1}" != 0 ] && [ -x "$KCLI" ]; then
  "$KCLI" probe --write --project "$PROJECT_DIR" </dev/null >/dev/null 2>&1 || hc_log "host probe failed"
fi
exit 0
