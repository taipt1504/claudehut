#!/usr/bin/env bash
# PostToolUse hook (matcher: Write|Edit) — ADVISORY doclint for the writer of a task artifact (06 §4, ADR-D1).
#
# The one run point that reaches a writer without Bash (the planner): after a Write/Edit of
#   .claude/claudehut/tasks/<id>/{spec,plan,brainstorm,plan-review,task,context}.md
# it runs `doclint.sh --advise` and passes its single summary line back as additionalContext. Every other path,
# no plane, no engine, an engine failure or an engine over DOCLINT_ADVISE_TIMEOUT (3 s) is exit 0 with empty
# stdout. Never blocks, never writes state (K8); the gate that refuses is `claudehut-state set-*`, inside an
# opted-in task. hooks.json narrows the spawn to Write(*.md)/Edit(*.md) (one rule per `if`); the case below
# narrows it to the artifact paths.

case "$0" in */*) _d="${0%/*}" ;; *) _d="." ;; esac
. "$_d/lib/hook-common.sh" 2>/dev/null || exit 0
hc_init
hc_plane_or_exit

fp="$(jq -r '.tool_input.file_path // empty' <<<"$HC_IN")"
hc_rel "$fp" || exit 0
case "$HC_REL" in .claude/claudehut/tasks/*/*.md) ;; *) exit 0 ;; esac
rest="${HC_REL#.claude/claudehut/tasks/}"; id="${rest%%/*}"; name="${rest#*/}"
case "$name" in spec.md|plan.md|brainstorm.md|plan-review.md|task.md|context.md) ;; *) exit 0 ;; esac
hc_safe_id "$id" || exit 0
[ -f "$_d/doclint.sh" ] || exit 0
[ -f "$PROJECT_DIR/$HC_REL" ] || exit 0

# Right-size from the artifact's own task (route/profile), when it is a schema-2 task.
a=(--advise --kind "${name%.md}")
tf="$PLANE/tasks/$id/task.json"
if [ -f "$tf" ]; then
  rp="$(jq -r 'if type=="object" and .schema==2 then "\(.route // "") \(.profile // "")" else " " end' "$tf" 2>/dev/null)" || rp=" "
  read -r route profile <<<"$rp"
  [ -z "$route" ] || a+=(--route "$route")
  [ -z "$profile" ] || a+=(--profile "$profile")
fi

# Time bound (default 3 s, under the 5 s hooks.json timeout): a hung engine is killed and the hook stays silent.
# The engine writes to a temp file outside the plane (K8), so a killed child holds no pipe open; the watchdog's
# own output goes to /dev/null for the same reason.
# No trap here: hc_init owns EXIT/ERR (K1), so every command that may fail sits in an && / || list.
of="$(mktemp "${TMPDIR:-/tmp}/doclint-advise.XXXXXX" 2>/dev/null)" || exit 0
bash "$_d/doclint.sh" "${a[@]}" "$PROJECT_DIR/$HC_REL" >"$of" 2>/dev/null &
pid=$!
( sleep "${DOCLINT_ADVISE_TIMEOUT:-3}" && { pkill -P "$pid"; kill "$pid"; } ) >/dev/null 2>&1 &
wd=$!
wait "$pid" 2>/dev/null && out="$(cat "$of" 2>/dev/null)" || out=""
{ pkill -P "$wd"; kill "$wd"; rm -f "$of"; } >/dev/null 2>&1 || true
line="${out%%$'\n'*}"
[ -n "$line" ] || exit 0
hc_ctx PostToolUse "ClaudeHut doclint ($id/$name): $line"
exit 0
