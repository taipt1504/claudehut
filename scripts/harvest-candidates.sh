#!/usr/bin/env bash
# Inline deterministic candidate harvester (v0.8 WS-6, Issue 5: Learn was slow).
# Run by claudehut:capture-learnings on the MAIN THREAD (it has Bash) BEFORE deciding whether to dispatch
# the sonnet learner — so a task with no novel signal pays ZERO agent round-trip. Extracts candidates from:
#   - this session's staged failures (state/<sid>.failures.jsonl) — a signature seen >=2x = a real recurring
#     pitfall (a one-off typo / intentional TDD RED is not).
#   - the task's review.md — coverage rows marked ✗/violated = findings worth recording.
# Appends valid JSONL to <task-dir>/learn-candidates.jsonl and prints the harvested count to stdout.
# Fails open (prints 0) when jq / inputs are missing. The merge-learnings quality gate drops weak candidates,
# so harvest can be generous.
set -uo pipefail
command -v jq >/dev/null 2>&1 || { echo 0; exit 0; }

SID=""; TASKDIR=""
while [ $# -gt 0 ]; do case "$1" in
  --session)  SID="${2:-}"; shift 2 ;;
  --task-dir) TASKDIR="${2:-}"; shift 2 ;;
  *) shift ;;
esac; done

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
[ -n "$TASKDIR" ] || { echo 0; exit 0; }
case "$TASKDIR" in /*) : ;; *) TASKDIR="$PROJECT_DIR/$TASKDIR" ;; esac
mkdir -p "$TASKDIR" 2>/dev/null || { echo 0; exit 0; }
OUT="$TASKDIR/learn-candidates.jsonl"
n=0

emit() { printf '%s\n' "$1" >> "$OUT" 2>/dev/null && n=$((n+1)); }

# 1) recurring failures → pitfalls (signature seen >=2x). Tolerant of the failure record's shape.
FAIL="$PROJECT_DIR/.claude/claudehut/state/$SID.failures.jsonl"
if [ -n "$SID" ] && [ -f "$FAIL" ]; then
  while IFS= read -r sig; do
    [ -n "$sig" ] || continue
    # LRN-3: count RECORDS whose own signature equals this one. `grep -cF` counted any line CONTAINING
    # the string anywhere — a signature that is a substring of another record's command inflated the count
    # and manufactured a "recurring" pitfall from a single failure.
    # count OCCURRENCES, not records: record-failure.sh collapses an immediately-repeated identical
    # failure into a .hits bump rather than a second line, so records alone undercount recurrence.
    cnt="$(jq -r --arg s "$sig" 'select((.stderr // .error // .signature // .command // .cmd // .detail // "") == $s) | (.hits // 1)' "$FAIL" 2>/dev/null | awk '{t+=$1} END{print t+0}')"
    [ "${cnt:-0}" -ge 2 ] || continue
    line="$(jq -nc --arg s "$sig" '
      ($s | ascii_downcase | [scan("[a-z0-9]+")] | map(select(length>3))[0:3]) as $kw
      | {category:"pitfall",
         trigger:(["build","error"] + $kw | join("|")),
         learning:("recurring build/dependency error this session: " + ($s[0:160])),
         evidence:"state/failures.jsonl", confidence:0.5}' 2>/dev/null || true)"
    [ -n "$line" ] && emit "$line"
    # LRN-3: `record-failure.sh` writes {command, exit, type, stderr} — none of .signature/.error/.cmd/
    # .detail. This read matched nothing on a real record, which is the second break in the harvest chain:
    # even once record-failure was fixed, the harvest could not see its output. stderr is the fingerprint,
    # because the SAME command failing for two different reasons is two different pitfalls; .command is a
    # fallback only for records with no message at all (an interrupt).
  done < <(jq -r '(.stderr // "" | select(length>0)) // (.signature // .error // .command // .cmd // .detail // empty)' "$FAIL" 2>/dev/null | grep -v '^$' | sort -u)
fi

# 2) review.md ✗/violated coverage rows → findings.
RV="$TASKDIR/review.md"
if [ -f "$RV" ]; then
  while IFS= read -r row; do
    item="$(printf '%s' "$row" | awk -F'|' 'NF>2{print $2}' | sed 's/^ *//;s/ *$//')"
    [ -n "$item" ] || continue
    ev="$(printf '%s' "$row" | grep -oE '[A-Za-z0-9_/]+\.(java|kt|kts|sql|ts)[:0-9]*' | head -1)"
    line="$(jq -nc --arg i "$item" --arg e "${ev:-no evidence}" '
      ($i | ascii_downcase | [scan("[a-z0-9]+")] | map(select(length>2))[0:3]) as $kw
      | {category:"finding", trigger:($kw | join("|")),
         learning:("review finding to avoid next time: " + $i), evidence:$e, confidence:0.5}' 2>/dev/null || true)"
    [ -n "$line" ] && emit "$line"
  done < <(grep -iE '^[[:space:]]*\|.*(✗|violated)' "$RV" 2>/dev/null)
fi

echo "$n"
