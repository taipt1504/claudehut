#!/usr/bin/env bash
# PostToolUse hook (matcher: Write|Edit) — reuse/duplication ADVISORY linter (v0.7, Issue 5).
#
# The recorded phases are structural (artifacts), so they cannot see "you just duplicated a helper"
# or "you re-implemented StringUtils.isBlank". This linter does — heuristically, AFTER the write — and
# stages a "reuse-suspect" the Review phase must clear. It is ADVISORY: it never blocks (PostToolUse
# can't), never errors the tool, exits 0 always. Enforcement is routed to Review (which loops until clean),
# matching the gate's fail-open philosophy — a heuristic false-positive must not wedge the user.
#
# Staging file: .claude/claudehut/state/<task-id>.suspects.jsonl  (per task, 05 §4 #7; under state/ = gitignored),
# read by claudehut:review and pasted into the reviewer prompt as "Known reuse suspects".
case "$0" in */*) _d="${0%/*}" ;; *) _d="." ;; esac
. "$_d/lib/hook-common.sh" 2>/dev/null || exit 0
hc_init
hc_plane_or_exit          # no plane → exit 0 and create nothing (K7)
in="$HC_IN"
trap - ERR                # this body predates the lib and relies on non-errexit semantics (a grep miss is
                          # a normal negative); the EXIT trap still guarantees exit 0 and a silent stdout

sid="$HC_SID"   # validated by hc_safe_id (empty when unsafe), so a '../' session_id cannot leave state/
fp="$(jq -r '.tool_input.file_path // empty' <<<"$in" 2>/dev/null || true)"
[ -n "$sid" ] && [ -n "$fp" ] || exit 0

# Production Java only: skip tests, non-java, and plugin/state artifacts.
case "$fp" in
  *Test.java|*IT.java|*/test/*|*/.claude/*) exit 0 ;;
  *.java) : ;;
  *) exit 0 ;;
esac
[ -f "$fp" ] || exit 0
# P-task (05 §3): only inside an active schema-2 task, and only for paths in its scope.
hc_active_task || exit 0
{ hc_rel "$fp" && hc_in_scope "$HC_REL"; } || exit 0

DIR="$PROJECT_DIR/.claude/claudehut/state"; F="$DIR/$HC_TASK_ID.suspects.jsonl"   # per task, not per session
mkdir -p "$DIR" 2>/dev/null || exit 0
rel="${fp#"$PROJECT_DIR"/}"
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '')"

emit() { # kind, detail
  local line; line="$(jq -nc --arg f "$rel" --arg k "$1" --arg d "$2" --arg t "$ts" \
    '{file:$f, kind:$k, detail:$d, ts:$t}' 2>/dev/null || true)"
  [ -n "$line" ] || return 0
  # dedup against an identical existing row (re-edits of the same file shouldn't pile up)
  grep -qF "$line" "$F" 2>/dev/null && return 0
  printf '%s\n' "$line" >> "$F"
}

# ── Flag 1: re-implemented stdlib / Apache Commons utility (the `isBlank` example).
STDLIB_RE='static[[:space:]]+[A-Za-z0-9_<>,. ]+[[:space:]](isBlank|isNotBlank|isEmpty|isNotEmpty|capitalize|uncapitalize|leftPad|rightPad|trimToNull|trimToEmpty|defaultIfBlank|defaultString)[[:space:]]*\('
if grep -qE "$STDLIB_RE" "$fp" 2>/dev/null; then
  hit="$(grep -oE "(isBlank|isNotBlank|isEmpty|isNotEmpty|capitalize|uncapitalize|leftPad|rightPad|trimToNull|trimToEmpty|defaultIfBlank|defaultString)" "$fp" 2>/dev/null | head -1)"
  emit "reinvented-stdlib" "declares static ${hit}() — Apache Commons StringUtils / JDK likely already ships it; reuse instead of hand-rolling"
fi

# ── Flag 2: a static helper whose name is ALSO declared in another production .java file (copy-paste dup).
names="$(grep -hoE 'static[[:space:]]+[A-Za-z0-9_<>,. ]+[[:space:]][a-zA-Z_][A-Za-z0-9_]*[[:space:]]*\(' "$fp" 2>/dev/null \
  | sed -E 's/.*[^A-Za-z0-9_]([A-Za-z0-9_]+)[[:space:]]*\(.*/\1/' | sort -u)"
SRC="$PROJECT_DIR/src/main"
[ -d "$SRC" ] || SRC="$PROJECT_DIR"
n_emitted=0
while IFS= read -r m; do
  [ -n "$m" ] || continue
  [ "$n_emitted" -ge 5 ] && break   # cap: don't flood on a utility-heavy file
  others="$(grep -rlE "static[[:space:]]+[A-Za-z0-9_<>,. ]+[[:space:]]${m}[[:space:]]*\(" "$SRC" --include='*.java' 2>/dev/null \
    | grep -vF "$fp" | grep -vE '(Test|IT)\.java$' | head -3)"
  if [ -n "$others" ]; then
    # Shell expansion, not a sed regex: a '#', '&', '.' or '*' in the project path broke or bent the pattern (V3-C3).
    where=""
    while IFS= read -r o; do where="$where${where:+,}${o#"$PROJECT_DIR"/}"; done <<<"$others"
    emit "duplicate" "static ${m}() also declared in: ${where} — extract ONE shared util instead of copies"
    n_emitted=$((n_emitted+1))
  fi
done <<<"$names"

exit 0
