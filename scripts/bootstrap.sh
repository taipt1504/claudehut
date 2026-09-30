#!/usr/bin/env bash
# SessionStart hook, SYNC (matcher: startup|resume|clear|compact|fork) — assemble context, nothing else
# (05 §5, ADR-H8). The first answer of a session waits on this hook, so every slow or writing step moved to
# maintain.sh (async): rule refresh, Summer KB install/self-heal, state sweep, log rotation.
#
# Removed in v0.12, with the finding each one caused:
#   - arming state at phase=discover on every session (A9, B2) — a session is task-free until `start`
#   - restoring the PreCompact snapshot (the PreCompact hook is gone)
#   - `claude plugin list` to detect understand-anything, 1–5 s per session (B10) — replaced by a file fact
#   - auto-init of a missing plane — no plane means ClaudeHut stays silent; init asks mono vs microservice
#   - "MUST use" lines (F-2) — context carries facts only
#
# Session id: exported through CLAUDE_ENV_FILE (probe P1 passed), plus a "Session id:" fallback line (B7).

case "$0" in */*) _d="${0%/*}" ;; *) _d="." ;; esac
HC_BUDGET=9500   # system cap is 10,000 chars per field; the ≤4,000 B target is measured by lint-prompt-length --payload
. "$_d/lib/hook-common.sh" 2>/dev/null || exit 0
hc_init
hc_plane_or_exit
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$_d/.." 2>/dev/null && pwd)}"

if [ "${CLAUDEHUT_DEBUG_PAYLOAD:-}" = "1" ]; then
  printf '%s\n' "$HC_IN" >> "$PLANE/state/payload-debug.SessionStart.jsonl"
fi

if [ -n "$HC_SID" ] && [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  printf 'export CLAUDEHUT_SESSION_ID=%s\n' "$HC_SID" >> "$CLAUDE_ENV_FILE" || hc_log "CLAUDE_ENV_FILE not writable"
fi

DIGEST="$PLUGIN_ROOT/skills/claudehut-workflow/references/digest.md"
ctx="$(cat "$DIGEST" 2>/dev/null || cat "$PLUGIN_ROOT/skills/claudehut-workflow/SKILL.md" 2>/dev/null)" \
  || ctx="ClaudeHut workflow digest not found."

# claudehut-state is not on PATH; stating the resolved path once saves the model a search per state write.
if [ -x "$PLUGIN_ROOT/bin/claudehut-state" ]; then
  ctx="$ctx"$'\n\n'"State CLI: \`$PLUGIN_ROOT/bin/claudehut-state\` (not on PATH; claudehut-init and claudehut-worktree live in the same directory)."
fi
[ -n "$HC_SID" ] && ctx="$ctx"$'\n'"Session id: $HC_SID"
if hc_active_task; then
  read -r t_route t_phase <<<"$(jq -r '"\(.route // "?") \(.phase // "?")"' <<<"$HC_TASK")"
  ctx="$ctx"$'\n'"Task đang mở: $HC_TASK_ID ($t_route, phase $t_phase)"
fi

if [ -s "$PLANE/learnings.jsonl" ]; then
  n_learn="$(grep -c '' "$PLANE/learnings.jsonl" 2>/dev/null)" || n_learn="?"
  ctx="$ctx"$'\n'"Learnings: $n_learn entries in .claude/claudehut/learnings.jsonl; the ones relevant to a prompt are added to that prompt."
fi

UA_GRAPH="$PROJECT_DIR/.understand-anything/knowledge-graph.json"
if [ -f "$UA_GRAPH" ]; then
  ua_day="$(date -r "$UA_GRAPH" +%Y-%m-%d 2>/dev/null)" || ua_day="unknown"
  ctx="$ctx"$'\n'"understand-anything graph: .understand-anything/knowledge-graph.json (modified $ua_day); readable with Read or jq."
fi

KB_META="$PROJECT_DIR/.claude/summer-kb/.summer-kb-meta.json"
if [ -f "$KB_META" ]; then
  read -r kb_commit kb_mods <<<"$(jq -r '"\((.summerCommit // "unknown")[0:7]) \((.includedModules // []) | join(","))"' "$KB_META" 2>/dev/null)"
  ctx="$ctx"$'\n'"Summer Framework KB: .claude/summer-kb/ (modules ${kb_mods:-unknown}; summerCommit ${kb_commit:-unknown}). Summer properties, auto-config gates, annotations and Kafka contracts are documented there; start at USAGE.md, then INDEX.md."
fi

hc_ctx SessionStart "$ctx"
exit 0
