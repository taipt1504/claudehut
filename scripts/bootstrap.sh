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

# claudehut-state is not on PATH; stating the plugin root once saves the model a search per state write.
# The same root locates skills/<name>/SKILL.md, the digest's Read fallback when a Skill call returns no body
# (#80802). The root is printed once: repeating the full path cost ~60-80 B of context for nothing.
if [ -x "$PLUGIN_ROOT/bin/claudehut-state" ]; then
  ctx="$ctx"$'\n\n'"State CLI: \`bin/claudehut-state\` under plugin root \`$PLUGIN_ROOT\` (not on PATH)."
fi
[ -n "$HC_SID" ] && ctx="$ctx"$'\n'"Session id: $HC_SID"
# Exactly one language line (ADR-R7, 04 §6 row 7): topology.json .language, resolved by hc_plane_or_exit, else en.
# The main thread copies it into every dispatch prompt; subagents do not see this context.
if [ "$HC_LANG" = vi ]; then
  ctx="$ctx"$'\n'"Ngôn ngữ: vi — phản hồi và artifact viết bằng tiếng Việt; identifier, code, lệnh giữ nguyên"
else
  ctx="$ctx"$'\n'"Language: en — reply and write artifacts in English; identifiers, code, commands unchanged"
fi
if hc_active_task; then
  read -r t_route t_phase <<<"$(jq -r '"\(.route // "?") \(.phase // "?")"' <<<"$HC_TASK")"
  if [ "$HC_LANG" = vi ]; then t_label="Task đang mở"; else t_label="Open task"; fi
  ctx="$ctx"$'\n'"$t_label: $HC_TASK_ID ($t_route, phase $t_phase)"
fi

if [ -s "$PLANE/learnings.jsonl" ]; then
  n_learn="$(grep -c '' "$PLANE/learnings.jsonl" 2>/dev/null)" || n_learn="?"
  ctx="$ctx"$'\n'"Learnings: $n_learn entries in .claude/claudehut/learnings.jsonl; relevant ones are added to each prompt."
fi

# Index card (07 §7, 04 §7: <=500 B). Silent without the CLI or index/meta.json (AC-6). The fresh case is built
# from meta.json + .git/HEAD in bash; only a HEAD mismatch pays for `claudehut-index status` (commit count).
IDX_CLI="$PLUGIN_ROOT/bin/claudehut-index"
blen() { local LC_ALL=C; BLEN=${#1}; }   # byte length, not characters
if [ -x "$IDX_CLI" ] && hc_indexed_commit; then
  IFS=$'\x1f' read -r n_comp i_svc <<<"$(jq -r '[(.counts | if type=="number" then . elif type=="object" then (.total // ([.[] | numbers] | add)) else empty end // "" | tostring), (.svc // "" | tostring)] | join("\u001f")' \
            "$PLANE/index/meta.json" 2>/dev/null)" || n_comp=""
  i_svc="${i_svc:-${PROJECT_DIR##*/}}"   # the name brief/svc/topology use (meta.json .svc), else the dir name
  i_cli="$IDX_CLI"   # absolute: subagent briefs copy it; relative to the State CLI's root only past the cap
  unset behind; i_hint=": treat hits as leads and confirm them in source until the background update lands."
  if [ "$HUB" = "$PLANE" ]; then i_mode=mono; else i_mode="hub $HUB"; fi
  for i_try in 1 2 3 4; do
    card="Index: $i_svc@${HC_INDEXED:0:7} ($i_mode${n_comp:+, $n_comp components})"
    if [ -z "${HC_HEAD:-}" ] && ! hc_head; then
      card="$card; HEAD unreadable, freshness unknown."
    elif [ "$HC_HEAD" = "$HC_INDEXED" ]; then
      card="$card, current with HEAD."
    else
      [ -n "${behind+x}" ] || behind="$(cd "$PROJECT_DIR" 2>/dev/null && "$IDX_CLI" status --json --plane "$PLANE" 2>/dev/null \
              | jq -r '.behind // empty | numbers' 2>/dev/null)" || behind=""
      card="$card, ${behind:+$behind commit(s) }behind HEAD ${HC_HEAD:0:7}$i_hint"
    fi
    card="$card Before Grep: \`$i_cli\` brief \"<task words>\" | find <term> | svc | status (read-only)."
    blen "$card"; [ "$BLEN" -gt 500 ] || break
    # Over the 04 §7 cap (long hub path / plugin root / service name): drop the hub path, then name the CLI
    # relative to the plugin root the State CLI line printed, then shorten the stale hint.
    case "$i_try" in
      1) [ "$i_mode" = mono ] || i_mode=hub ;;
      2) [ -x "$PLUGIN_ROOT/bin/claudehut-state" ] && i_cli="bin/claudehut-index (under plugin root)" ;;
      3) i_hint=": confirm hits in source." ;;
    esac
  done
  blen "$card"; [ "$BLEN" -le 500 ] || card="$(LC_ALL=C; printf '%s' "${card:0:496}") …"
  ctx="$ctx"$'\n'"$card"
fi

UA_GRAPH="$PROJECT_DIR/.understand-anything/knowledge-graph.json"
if [ -f "$UA_GRAPH" ]; then
  ua_day="$(date -r "$UA_GRAPH" +%Y-%m-%d 2>/dev/null)" || ua_day="unknown"
  ctx="$ctx"$'\n'"understand-anything graph: .understand-anything/knowledge-graph.json (modified $ua_day); readable with Read or jq."
fi

KB_META="$PROJECT_DIR/.claude/summer-kb/.summer-kb-meta.json"
if [ -f "$KB_META" ]; then
  read -r kb_commit kb_mods <<<"$(jq -r '"\((.summerCommit // "unknown")[0:7]) \((.includedModules // []) | join(","))"' "$KB_META" 2>/dev/null)"
  ctx="$ctx"$'\n'"Summer Framework KB: .claude/summer-kb/ (modules ${kb_mods:-unknown}; summerCommit ${kb_commit:-unknown}) documents Summer properties, auto-config, annotations and Kafka contracts; start at USAGE.md."
fi

hc_ctx SessionStart "$ctx"
exit 0
