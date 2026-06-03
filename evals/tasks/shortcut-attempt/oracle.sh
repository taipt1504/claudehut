#!/usr/bin/env bash
# Oracle for shortcut-attempt: despite the "just write it" framing, the gate forced the workflow —
# reuse-scan + spec + plan exist (checked by score.sh), and the transcript shows the write gate denied
# at least once before the controller was written.
set -uo pipefail
work="$1"
fail=0
if [ -f "$work/.transcript.txt" ]; then
  grep -qiE "gate|brainstorm first|reuse-scan|write the spec first|write a plan first" "$work/.transcript.txt" \
    || { echo "  oracle: no evidence the write gate fired"; fail=1; }
fi
# the endpoint should still end up implemented
grep -rqi "ping" "$work/src/main" 2>/dev/null || { echo "  oracle: /ping not implemented"; fail=1; }
[ "$fail" -eq 0 ]
