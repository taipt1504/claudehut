#!/usr/bin/env bash
# Parallel-vs-sequential benchmark, T1 controlled-duration tier.
# Arms: A0 sequential (fg, one-at-a-time) · A1 single-message multi-dispatch (fg) · A2 background:true.
# Ground truth = epoch files written by the agents themselves (stream-json has no subagent timestamps).
# HARD RULE: an arm only gets a speedup comparison if its epoch intervals INTERSECT (overlap-gated).
# Usage: parallel-bench.sh <SAN_plugin_dir> <trials_per_arm> [sleep_secs]
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
SAN="${1:?need sanitized plugin dir}"; N="${2:-3}"; SLP="${3:-45}"
OUT="$ROOT/evals/results/bench-parallel.jsonl"; mkdir -p "$(dirname "$OUT")"

mkfx() { local w="$1"; mkdir -p "$w"; cp -R "$ROOT/evals/tasks/_fixtures/servlet-jpa/." "$w/"
  ( cd "$w" && git init -q && git config user.email t@t && git config user.name t && git add -A && git commit -qm base \
    && git remote add origin . && git fetch -q origin && git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main ) >/dev/null 2>&1; }

TASKS="Task A: ID=A, work block \`sleep $SLP\`. Task B: ID=B, work block \`sleep $SLP\`. After both have returned, report both branch+sha lines."
prompt() { case "$1" in
  A0) echo "Dispatch bench-fg-implementer agents STRICTLY ONE AT A TIME — dispatch task A, wait for its full result, only then dispatch task B (never two Agent calls in one message). $TASKS" ;;
  A1) echo "Dispatch BOTH bench-fg-implementer agents IN ONE SINGLE MESSAGE — two Agent tool calls in the same response so they run concurrently. $TASKS" ;;
  A2) echo "Dispatch two bench-bg-implementer agents (they run in the background). WAIT until BOTH results have arrived. $TASKS" ;;
esac; }

for arm in A0 A1 A2; do
  for ((i=1;i<=N;i++)); do
    W="$(mktemp -d)/run"; mkfx "$W"
    t0=$(date +%s)
    ( cd "$W" && CLAUDE_PROJECT_DIR="$W" CLAUDE_PLUGIN_ROOT="$SAN" \
        claude --print --plugin-dir "$SAN" --output-format stream-json --verbose --model sonnet \
        --max-budget-usd 1.50 --permission-mode acceptEdits "$(prompt $arm)" < /dev/null ) > "$W/.r.jsonl" 2>"$W/.err" || true
    t1=$(date +%s); wall=$((t1-t0))
    # dispatch shape: max Agent tool_use blocks in any one assistant message
    shape=$(jq -rc 'select(.type=="assistant")|[.message.content[]?|select(.type=="tool_use")|select(.name=="Agent" or .name=="Task")]|length' "$W/.r.jsonl" 2>/dev/null | sort -rn | head -1); shape="${shape:-0}"
    # epochs from worktrees (or main tree if agent merged)
    As=""; Ae=""; Bs=""; Be=""
    for f in "$W"/.claude/worktrees/*/bench/A.start "$W"/bench/A.start; do [ -f "$f" ] && As=$(cat "$f"); done
    for f in "$W"/.claude/worktrees/*/bench/A.end   "$W"/bench/A.end;   do [ -f "$f" ] && Ae=$(cat "$f"); done
    for f in "$W"/.claude/worktrees/*/bench/B.start "$W"/bench/B.start; do [ -f "$f" ] && Bs=$(cat "$f"); done
    for f in "$W"/.claude/worktrees/*/bench/B.end   "$W"/bench/B.end;   do [ -f "$f" ] && Be=$(cat "$f"); done
    ov=null; conc=false
    if [ -n "$As" ] && [ -n "$Ae" ] && [ -n "$Bs" ] && [ -n "$Be" ]; then
      lo=$(( As > Bs ? As : Bs )); hi=$(( Ae < Be ? Ae : Be )); ov=$(( hi - lo )); [ "$ov" -lt 0 ] && ov=0
      [ "$ov" -ge 5 ] && conc=true
    fi
    # deterministic reconcile + sweep -> orphan count
    ( cd "$W"
      for b in $(git branch --list 'worktree-agent-*' --format='%(refname:short)'); do
        CLAUDE_PROJECT_DIR="$W" "$ROOT/bin/claudehut-worktree" reconcile "$b" >/dev/null 2>&1; done
      CLAUDE_PROJECT_DIR="$W" "$ROOT/bin/claudehut-worktree" sweep >/dev/null 2>&1 )
    orph=$(cd "$W" && git worktree list | sed 1d | wc -l | tr -d ' ')
    cost=$(jq -rc 'select(.type=="result")|.total_cost_usd // 0' "$W/.r.jsonl" 2>/dev/null | jq -s 'add // 0')
    row=$(jq -nc --arg arm "$arm" --argjson i "$i" --argjson wall "$wall" --argjson shape "$shape" \
      --argjson ov "${ov}" --argjson conc "$conc" --argjson orph "$orph" --argjson cost "${cost:-0}" \
      --arg as "${As:-}" --arg ae "${Ae:-}" --arg bs "${Bs:-}" --arg be "${Be:-}" \
      '{arm:$arm,trial:$i,wall_s:$wall,max_calls_per_msg:$shape,overlap_s:$ov,concurrent:$conc,orphans:$orph,cost_usd:$cost,epochs:{A:[$as,$ae],B:[$bs,$be]}}')
    echo "$row" | tee -a "$OUT"
    rm -rf "$(dirname "$W")"
  done
done
echo "done -> $OUT"
