#!/usr/bin/env bash
# update-usefulness.sh TASK_ID
#
# Phase 4.3 — outcome-signal usefulness prior. After a task, credit the learnings
# that were retrieved for it (the retrieval log) by their pass/fail outcome:
#   used  += 1   (always — the learning was surfaced)
#   useful += 1  (iff findings.decision == "pass")
# into .claudehut/memory/usefulness.json, keyed by the SHARED learning_key.
# retrieve-relevant.sh reads these back as S_prior = (useful+1)/(used+2) (Laplace).
#
# HONESTY (v1): this is a SUCCESS-RECURRENCE prior. The learn phase is pass-gated
# (state.sh), so in v1 the only callsite (the learn pipeline) runs with
# decision="pass" → used and useful co-increment → S_prior is monotone-up. The
# fail branch below IS wired (and proven by the test) but is unreachable until a
# non-pass callsite exists — that is the deferred 4.4 seam, NOT dead code. It is
# not "reinforcement learning"; downward pressure in v1 is the Laplace denominator.
set -uo pipefail

TASK_ID="${1:-}"
[[ -n "$TASK_ID" ]] || { echo "usage: update-usefulness.sh <task-id>" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 2; }

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
STATE_DIR="$PROJECT_ROOT/.claudehut/state"
MEM_DIR="$PROJECT_ROOT/.claudehut/memory"
RET_LOG="$STATE_DIR/retrieval-${TASK_ID}.json"
MARKER="$STATE_DIR/usefulness-scored-${TASK_ID}.marker"
SIDECAR="$MEM_DIR/usefulness.json"
FINDINGS="$PROJECT_ROOT/.claudehut/findings/${TASK_ID}-findings.json"

# Idempotency: never double-credit a task.
[[ -f "$MARKER" ]] && { echo "already scored: $TASK_ID"; exit 0; }
# No retrieval happened for this task → nothing to credit.
[[ -s "$RET_LOG" ]] || { echo "no retrieval log for $TASK_ID"; exit 0; }

# Dedup the union of sigs across all phases' appended log lines.
SIGS="$(jq -s '[.[]?.sigs[]?] | unique' "$RET_LOG" 2>/dev/null || echo '[]')"
[[ "$SIGS" == "[]" || -z "$SIGS" ]] && { echo "no sigs in retrieval log"; exit 0; }

DECISION="$(jq -r '.decision // ""' "$FINDINGS" 2>/dev/null || echo "")"
[[ -n "$DECISION" ]] || { echo "no decision yet for $TASK_ID"; exit 0; }

mkdir -p "$MEM_DIR" "$STATE_DIR"
CUR='{}'
[[ -s "$SIDECAR" ]] && CUR="$(jq -c '.' "$SIDECAR" 2>/dev/null || echo '{}')"

# used += 1 for each sig; useful += 1 only on pass.
PASS="false"; [[ "$DECISION" == "pass" ]] && PASS="true"
NEW="$(printf '%s' "$CUR" | jq -c --argjson sigs "$SIGS" --argjson pass "$PASS" '
  reduce $sigs[] as $s (.;
    .[$s] = { used: ((.[$s].used // 0) + 1),
              useful: ((.[$s].useful // 0) + (if $pass then 1 else 0 end)) })
' 2>/dev/null || echo "")"
[[ -n "$NEW" ]] || { echo "usefulness update failed (left sidecar untouched)" >&2; exit 0; }

# Atomic write (same-dir tmp + mv — promote.sh pattern).
TMP="$SIDECAR.tmp.$$"
printf '%s\n' "$NEW" > "$TMP" && mv "$TMP" "$SIDECAR"
: > "$MARKER"
N="$(printf '%s' "$SIGS" | jq 'length' 2>/dev/null || echo '?')"
echo "usefulness updated: $TASK_ID decision=$DECISION sigs=$N (useful credited: $PASS)"
exit 0
