#!/usr/bin/env bash
# Scores one completed scenario run. Asserts the workflow's mechanical signature:
#   (a) the reuse-scan artifact exists, (b) a spec exists, (c) a plan exists,
#   (d) a learnings.jsonl entry was added, and (e) the task's own oracle.sh passes.
# Usage: evals/score.sh <work-dir> <task-dir>
# Artifacts live in the CANONICAL per-task store tasks/NNNN-<slug>/{reuse-scan,spec,plan}.md
# (legacy flat reuse-scan-*.md/specs/plans/ accepted as fallback) — checking only the flat
# layout was the false "fail #5" (canonical runs scored as misses). See EVAL-REPORT.
set -uo pipefail
work="$1"; task="$2"
chd="$work/.claude/claudehut"
pass=0; fail=0
chk() { if eval "$2"; then pass=$((pass+1)); echo "  ok   - $1"; else fail=$((fail+1)); echo "  FAIL - $1"; fi; }

chk "reuse-scan artifact produced"   "ls '$chd'/tasks/*/reuse-scan.md >/dev/null 2>&1 || ls '$chd'/reuse-scan-*.md >/dev/null 2>&1"
chk "spec produced"                  "ls '$chd'/tasks/*/spec.md       >/dev/null 2>&1 || ls '$chd'/specs/*.md      >/dev/null 2>&1"
chk "plan produced"                  "ls '$chd'/tasks/*/plan.md       >/dev/null 2>&1 || ls '$chd'/plans/*.md      >/dev/null 2>&1"
chk "learnings recorded"             "[ -s '$chd/learnings.jsonl' ]"
if [ -x "$task/oracle.sh" ]; then
  chk "task oracle" "'$task/oracle.sh' '$work' >/dev/null 2>&1"
fi
echo "  ($pass ok, $fail fail)"
[ "$fail" -eq 0 ]
