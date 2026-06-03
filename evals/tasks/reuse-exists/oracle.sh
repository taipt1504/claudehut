#!/usr/bin/env bash
# Oracle for reuse-exists: the reuse-scan must reference the existing TextUtils, and NO duplicate
# slug implementation should have been created (the agent adopts/extends the existing util).
set -uo pipefail
work="$1"; chd="$work/.claude/claudehut"
fail=0
grep -rqi "TextUtils" "$chd"/reuse-scan-*.md 2>/dev/null || { echo "  oracle: reuse-scan did not reference TextUtils"; fail=1; }
# count slugify implementations under src/main — must remain exactly 1 (the original)
n=$(grep -rl "String slugify" "$work/src/main" 2>/dev/null | wc -l | tr -d ' ')
[ "$n" = "1" ] || { echo "  oracle: expected 1 slugify impl (reuse), found $n"; fail=1; }
[ "$fail" -eq 0 ]
