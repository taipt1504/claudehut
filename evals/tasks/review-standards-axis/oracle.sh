#!/usr/bin/env bash
# Oracle for review-standards-axis (v0.7 — Requirement #6 headline: Standards-axis review rigor).
# The task tempts TWO Standards-axis defects: a string→enum converter DUPLICATED across ItemService +
# OrderService, and a fully-qualified `java.util.List` written inline instead of imported.
#
# R6's underlying goal is that these do not SHIP. That goal is met whether Implement prevented them (design
# beat / reuse) or Review caught them — so this oracle is end-to-end: the shipped tree must be clean AND the
# review must have ENGAGED the Standards axis (a coverage row for FQN/duplication), proving it looked.
# Heuristic static checks on the final tree + review artifact — debuggable, tune patterns on a false-negative.
set -uo pipefail
work="$1"; src="$work/src/main"; chd="$work/.claude/claudehut"
ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
. "$ROOT/evals/lib/artifact-checks.sh" 2>/dev/null || true
fail=0
chk() { if eval "$2"; then echo "  oracle ✓ $1"; else echo "  oracle ✗ $1"; fail=1; fi; }

# Feature implemented at all.
chk "parseStatus implemented" 'grep -rqiE "parseStatus" "$src" 2>/dev/null'

# OUTCOME 1 — converter NOT duplicated: the actual string→enum CONVERSION LOGIC (valueOf + case-normalize)
# must live in AT MOST ONE file. A delegating wrapper (`return Status.parse(raw);`) is NOT duplication — so
# count only files carrying the real conversion (valueOf co-occurring with toUpper/toLowerCase), not files
# that merely declare a parseStatus method that delegates. (v0.7 oracle fix: the naive method-presence count
# false-flagged centralized-with-delegation, which is the CORRECT design the reuse/design-beat produces.)
n_conv=0
while IFS= read -r jf; do
  [ -n "$jf" ] || continue
  grep -qE 'toUpperCase|toLowerCase' "$jf" 2>/dev/null && n_conv=$((n_conv+1))
done < <(grep -rlE 'valueOf' "$src" --include='*.java' 2>/dev/null)
chk "string→enum conversion logic not duplicated (<=1 site, got ${n_conv})" '[ "${n_conv}" -le 1 ]'

# OUTCOME 2 — no fully-qualified java.util.List written inline in a declaration (import it instead).
chk "no inline FQN java.util.List in shipped code" '! grep -rqE "java\.util\.List<" "$src" 2>/dev/null'

# ENGAGEMENT — review.md carries a Standards-axis row (FQN / duplication / convention), proving the two-axis
# review actually considered them (✓, ✗, or n-a — silence is the failure the requirement targets).
rv="$(ls "$chd"/tasks/*/review.md 2>/dev/null | head -1)"
chk "review.md engaged the Standards axis (FQN/duplication/convention row)" \
  '[ -n "$rv" ] && grep -qiE "duplicat|fully.?qualif|FQN|convention|standards" "$rv" 2>/dev/null'

# Workflow reached an earned pass.
st=$(ls -t "$chd"/state/*.json 2>/dev/null | head -1)
chk "review reached pass with recorded evidence" \
  '[ -n "$st" ] && jq -e ".review==\"pass\" and (.review_evidence|type==\"string\")" "$st" >/dev/null 2>&1'

[ "$fail" -eq 0 ]
