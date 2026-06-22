#!/usr/bin/env bash
# One-off diagnostic: init-then-task on clean-first-run, with workdir + transcript captured,
# to determine whether the ClaudeHut workflow actually drives (produces reuse-scan/spec/plan/
# learnings + state) and whether the write gate fires. Not part of the suite.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
SAN="$(mktemp -d)/plugin"; cp -R "$ROOT" "$SAN"; rm -rf "$SAN/evals" "$SAN/docs" "$SAN/.git"
work="$(mktemp -d)/work"; mkdir -p "$work"; cp -R "$ROOT/evals/tasks/clean-first-run/repo/." "$work/"
( cd "$work" && git init -q && git add -A && git commit -qm base >/dev/null 2>&1 )
echo "WORK=$work"
echo "=== INIT call ==="
( cd "$work" && CLAUDE_PROJECT_DIR="$work" CLAUDE_PLUGIN_ROOT="$SAN" \
   claude --print --plugin-dir "$SAN" --output-format json --model sonnet --max-budget-usd 1.20 \
   --permission-mode acceptEdits "Bootstrap this project for ClaudeHut: run the claudehut-init bootstrap to detect the stack and generate the project index, memory, and path-scoped rules." < /dev/null ) \
   > "$work/.init.json" 2>"$work/.init.err" || true
echo "  init cost: $(jq -r '.total_cost_usd // "?"' "$work/.init.json" 2>/dev/null)  is_error: $(jq -r '.is_error // "?"' "$work/.init.json" 2>/dev/null)"
echo "  post-init .claude/claudehut tree:"; find "$work/.claude" -maxdepth 3 2>/dev/null | sed "s#$work/##" | head -30
echo "=== TASK call (stream-json) ==="
( cd "$work" && CLAUDE_PROJECT_DIR="$work" CLAUDE_PLUGIN_ROOT="$SAN" \
   claude --print --plugin-dir "$SAN" --output-format stream-json --verbose --model sonnet --max-budget-usd 2.00 \
   --permission-mode acceptEdits "$(cat "$ROOT/evals/tasks/clean-first-run/task.md")

Follow the ClaudeHut 6-phase workflow (brainstorm with reuse scan → spec → plan → implement test-first → review → learn) to completion." < /dev/null ) \
   > "$work/.task.stream.jsonl" 2>"$work/.task.err" || true
echo "  post-task .claude/claudehut tree:"; find "$work/.claude/claudehut" 2>/dev/null | sed "s#$work/##" | head -40
echo "  workflow artifacts: reuse=$(ls "$work/.claude/claudehut"/tasks/*/reuse-scan.md "$work/.claude/claudehut"/reuse-scan-*.md 2>/dev/null|wc -l|tr -d ' ') spec=$(ls "$work/.claude/claudehut"/tasks/*/spec.md "$work/.claude/claudehut"/specs/*.md 2>/dev/null|wc -l|tr -d ' ') plan=$(ls "$work/.claude/claudehut"/tasks/*/plan.md "$work/.claude/claudehut"/plans/*.md 2>/dev/null|wc -l|tr -d ' ') learn=$([ -s "$work/.claude/claudehut/learnings.jsonl" ]&&echo 1||echo 0) state=$(ls "$work/.claude/claudehut/state"/*.json 2>/dev/null|wc -l|tr -d ' ')"
echo "  tool_use invoked (name x count):"
grep '^{' "$work/.task.stream.jsonl" 2>/dev/null | jq -rc 'select(.type=="assistant")|.message.content[]?|select(.type=="tool_use")|.name' 2>/dev/null | sort | uniq -c
echo "  Skill invocations (claudehut:*):"
grep -oE 'claudehut:[a-z-]+' "$work/.task.stream.jsonl" 2>/dev/null | sort | uniq -c | head
echo "  gate-deny messages in transcript: $(grep -c -i 'ClaudeHut gate' "$work/.task.stream.jsonl" 2>/dev/null || echo 0)"
echo "  src java files: $(find "$work/src" -name '*.java' 2>/dev/null | sed "s#$work/##")"
echo "  task result is_error: $(grep '^{' "$work/.task.stream.jsonl"|jq -rc 'select(.type=="result")|{subtype,is_error,total_cost_usd,num_turns}' 2>/dev/null|tail -1)"
echo "DIAG DONE work=$work"
