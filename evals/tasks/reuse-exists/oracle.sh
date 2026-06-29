#!/usr/bin/env bash
# Oracle for reuse-exists: the reuse-scan must reference the existing TextUtils, and NO duplicate
# slug implementation should have been created (the agent adopts/extends the existing util).
set -uo pipefail
work="$1"; chd="$work/.claude/claudehut"
fail=0
# canonical per-task store first (tasks/NNNN-<slug>/reuse-scan.md), legacy flat as fallback
{ grep -rqi "TextUtils" "$chd"/tasks/*/reuse-scan.md 2>/dev/null || grep -rqi "TextUtils" "$chd"/reuse-scan-*.md 2>/dev/null; } \
  || { echo "  oracle: reuse-scan did not reference TextUtils"; fail=1; }
# count slugify ALGORITHM implementations under src/main — must remain exactly 1 (the original TextUtils).
# v0.7 oracle fix: count only files carrying the real transform (replaceAll/regex/toLowerCase-chain), NOT
# delegating wrappers. Adopting TextUtils via a thin service method `String slugify(t){return TextUtils.slugify(t);}`
# is CORRECT reuse, not duplication — the naive `grep "String slugify"` count flagged that wrapper as a 2nd
# impl (same delegation-vs-duplication false-negative fixed in the R6 fixture). A genuine re-implementation
# (agent re-wrote the regex) still carries the algorithm markers → still counted → still fails.
n=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  grep -qE 'replaceAll|toLowerCase\(\)\.|Pattern\.compile|\.matcher\(|[Nn]ormalize' "$f" 2>/dev/null && n=$((n+1))
done < <(grep -rl "slugify" "$work/src/main" 2>/dev/null)
[ "$n" = "1" ] || { echo "  oracle: expected 1 slugify ALGORITHM impl (reuse, not re-implement), found $n"; fail=1; }
[ "$fail" -eq 0 ]
