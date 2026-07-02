#!/usr/bin/env bash
# Oracle for observability-review (v0.9 Rec 3 — observability as a first-class Review gate).
# The fixture ships an UNINSTRUMENTED endpoint; a rigorous review must ensure the shipped operation carries a
# Micrometer meter / @Timed / @Observed AND its review.md engaged the observability axis. End-to-end static
# checks on the final tree + review artifact — the goal is met whether Implement instrumented up front or
# Review caught the gap. Heuristic grep/jq checks — debuggable; tune patterns on a false-negative.
set -uo pipefail
work="$1"; src="$work/src/main"; chd="$work/.claude/claudehut"
ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
. "$ROOT/evals/lib/artifact-checks.sh" 2>/dev/null || true
fail=0
chk() { if eval "$2"; then echo "  oracle ✓ $1"; else echo "  oracle ✗ $1"; fail=1; fi; }

# Feature implemented at all.
chk "summary endpoint implemented" 'grep -rqiE "summary" "$src" 2>/dev/null'

# OUTCOME — the shipped operation is METERED (Micrometer timer/counter, @Timed, or Observation API).
chk "operation is instrumented (Micrometer @Timed/@Observed/Observation/MeterRegistry/Timer/Counter)" \
  'grep -rqE "@Timed|@Observed|Observation|MeterRegistry|ObservationRegistry|io\.micrometer|Metrics\.|Timer\.|Counter\." "$src" 2>/dev/null'

# ENGAGEMENT — review.md carries an observability-axis row (metric / tracing / SLO / instrumentation), proving
# the review actually considered it (✓, ✗, or n-a — silence is the failure the requirement targets).
rv="$(ls "$chd"/tasks/*/review.md 2>/dev/null | head -1)"
chk "review.md engaged the observability axis (metric/trace/SLO/instrumentation row)" \
  '[ -n "$rv" ] && grep -qiE "observab|metric|micrometer|trac(e|ing)|SLO|@Timed|@Observed|instrument" "$rv" 2>/dev/null'

# Workflow reached an earned pass with recorded evidence.
st=$(ls -t "$chd"/state/*.json 2>/dev/null | head -1)
chk "review reached pass with recorded evidence" \
  '[ -n "$st" ] && jq -e ".review==\"pass\" and (.review_evidence|type==\"string\")" "$st" >/dev/null 2>&1'

[ "$fail" -eq 0 ]
