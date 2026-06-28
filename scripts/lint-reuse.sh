#!/usr/bin/env bash
# PostToolUse hook (matcher: Write|Edit) — reuse/duplication ADVISORY linter (v0.7, Issue 5).
#
# The write gate is structural (artifact + skill-rail), so it cannot see "you just duplicated a helper"
# or "you re-implemented StringUtils.isBlank". This linter does — heuristically, AFTER the write — and
# stages a "reuse-suspect" the Review phase must clear. It is ADVISORY: it never blocks (PostToolUse
# can't), never errors the tool, exits 0 always. Enforcement is routed to Review (which loops until clean),
# matching the gate's fail-open philosophy — a heuristic false-positive must not wedge the user.
#
# Staging file: .claude/claudehut/state/<sid>.suspects.jsonl  (under state/ = gitignored/ephemeral),
# read by claudehut:review and pasted into the reviewer prompt as "Known reuse suspects".
set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
in="$(cat || true)"
command -v jq >/dev/null 2>&1 || exit 0

sid="$(jq -r '.session_id // empty' <<<"$in" 2>/dev/null || true)"
fp="$(jq -r '.tool_input.file_path // empty' <<<"$in" 2>/dev/null || true)"
[ -n "$sid" ] && [ -n "$fp" ] || exit 0

# Production Java only: skip tests, non-java, and plugin/state artifacts.
case "$fp" in
  *Test.java|*IT.java|*/test/*|*/.claude/*) exit 0 ;;
  *.java) : ;;
  *) exit 0 ;;
esac
[ -f "$fp" ] || exit 0

DIR="$PROJECT_DIR/.claude/claudehut/state"; F="$DIR/$sid.suspects.jsonl"
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
    where="$(printf '%s' "$others" | sed "s#^${PROJECT_DIR}/##" | tr '\n' ',' | sed 's/,$//')"
    emit "duplicate" "static ${m}() also declared in: ${where} — extract ONE shared util instead of copies"
    n_emitted=$((n_emitted+1))
  fi
done <<<"$names"

exit 0
