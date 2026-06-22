#!/usr/bin/env bash
# Scenario runner + live benchmark for ClaudeHut.
# Dry-run by DEFAULT (free). --live drives real `claude --print` (COSTS TOKENS). --trials N repeats.
# Usage: evals/run.sh [--live] [--trials N] [--mode claudehut|baseline] [--no-init] [task ...]
# Env:   CLAUDEHUT_EVAL_BUDGET (default 3.00)  CLAUDEHUT_EVAL_MODEL (default sonnet)
#
# claudehut mode: (1) optional init call to bootstrap, then (2) the task call — both against a SANITIZED
# plugin copy (evals/ docs/ .git stripped) so the agent can't read the held-out oracle (answer-key guard).
#
# SECURITY NOTE: live runs use --dangerously-skip-permissions (CC ≥2.1.x headless flags .claude/** writes
# as "sensitive" even under acceptEdits + allow rules, deadlocking the workflow; the ClaudeHut deny-hooks
# were live-probed to still block under this flag). The eval agent therefore runs UNSANDBOXED with your
# user's filesystem access — only run evals with fixtures from THIS repo that you trust.
# Workflow progress is read from the AUTHORITATIVE per-session state file (phase/reuse_scan/spec/plan/review),
# not from artifact paths — the agent may write artifacts to non-canonical locations (a measured defect).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TASKS_DIR="$ROOT/evals/tasks"; RESULTS_DIR="$ROOT/evals/results"
LIVE=false; TRIALS=1; MODE=claudehut; DO_INIT=true; args=()
while [ $# -gt 0 ]; do case "$1" in
  --live) LIVE=true; shift ;;
  --trials) TRIALS="${2:-1}"; shift 2 ;;
  --mode) MODE="${2:-claudehut}"; shift 2 ;;
  --no-init) DO_INIT=false; shift ;;
  *) args+=("$1"); shift ;;
esac; done
case "$MODE" in claudehut|baseline) ;; *) echo "mode must be claudehut|baseline" >&2; exit 2 ;; esac
# NB: "${args[@]}" on an empty array under `set -u` is an unbound-variable error on bash 3.2
# (macOS default) — guard by length before expanding.
sel=(); [ ${#args[@]} -gt 0 ] && sel=("${args[@]}")
[ ${#sel[@]} -eq 0 ] && sel=($(ls "$TASKS_DIR"))
BUDGET="${CLAUDEHUT_EVAL_BUDGET:-3.00}"; MODEL="${CLAUDEHUT_EVAL_MODEL:-sonnet}"
mkdir -p "$RESULTS_DIR"

if ! $LIVE; then
  echo "(dry run — pass --live to drive Claude Code; costs tokens). mode=$MODE trials=$TRIALS init=$DO_INIT tasks: ${sel[*]}"
  exit 0
fi
command -v claude >/dev/null || { echo "claude not on PATH" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq not on PATH" >&2; exit 2; }
num() { case "$1" in ''|*[!0-9.]*) echo 0 ;; *) echo "$1" ;; esac; }

SAN=""
if [ "$MODE" = claudehut ]; then SAN="$(mktemp -d)/plugin"; cp -R "$ROOT" "$SAN"; rm -rf "$SAN/evals" "$SAN/docs" "$SAN/.git"; fi

for t in "${sel[@]}"; do
  d="$TASKS_DIR/$t"; [ -d "$d/repo" ] || { echo "skip: no fixture $t"; continue; }
  prompt="$(cat "$d/task.md")"
  for ((i=1;i<=TRIALS;i++)); do
    work="$(mktemp -d)/work"; mkdir -p "$work"; cp -R "$d/repo/." "$work/"
    # CC ≥2.1.x headless treats .claude/** edits as "sensitive" — acceptEdits does NOT auto-approve them,
    # which deadlocks the workflow (artifacts live under .claude/claudehut/). Allow them explicitly.
    mkdir -p "$work/.claude"
    printf '{"permissions":{"allow":["Write(.claude/claudehut/**)","Edit(.claude/claudehut/**)","Write(./.claude/claudehut/**)","Edit(./.claude/claudehut/**)"]}}\n' > "$work/.claude/settings.json"
    ( cd "$work" && git init -q && git add -A && git commit -qm base >/dev/null 2>&1 )
    j="$work/.eval.json"; icost=0
    start=$(date +%s)
    if [ "$MODE" = baseline ]; then
      ( cd "$work" && claude --print --output-format json --model "$MODEL" --max-budget-usd "$BUDGET" \
          --dangerously-skip-permissions "$prompt" < /dev/null ) > "$j" 2>"$work/.err" || true
    else
      if $DO_INIT; then
        ( cd "$work" && CLAUDE_PROJECT_DIR="$work" CLAUDE_PLUGIN_ROOT="$SAN" \
            claude --print --plugin-dir "$SAN" --output-format json --model "$MODEL" --max-budget-usd 1.20 \
            --dangerously-skip-permissions "Bootstrap this project for ClaudeHut: run claudehut-init to detect the stack and generate the project index, memory, and path-scoped rules under .claude/claudehut/." < /dev/null ) \
            > "$work/.init.json" 2>"$work/.init.err" || true
        icost=$(num "$(jq -r '.total_cost_usd // 0' "$work/.init.json" 2>/dev/null)")
      fi
      full="$prompt

This project uses the ClaudeHut plugin; its 7-phase workflow is injected at session start. Drive the ClaudeHut workflow to completion: triage the complexity tier FIRST (Phase 0 — set-complexity trivial/small/full), then run exactly that tier's phases, writing all workflow artifacts under .claude/claudehut/. Complete the task."
      ( cd "$work" && CLAUDE_PROJECT_DIR="$work" CLAUDE_PLUGIN_ROOT="$SAN" \
          claude --print --plugin-dir "$SAN" --output-format json --model "$MODEL" --max-budget-usd "$BUDGET" \
          --dangerously-skip-permissions "$full" < /dev/null ) > "$j" 2>"$work/.err" || true
    fi
    end=$(date +%s); wall=$(( (end - start) * 1000 ))
    tcost=$(num "$(jq -r '.total_cost_usd // 0' "$j" 2>/dev/null)")
    cost=$(echo "$icost + $tcost" | bc 2>/dev/null || echo "$tcost")
    iserr=$(jq -r '.is_error // true' "$j" 2>/dev/null); [ "$iserr" = true ] || [ "$iserr" = false ] || iserr=true
    sub=$(jq -r '.subtype // "unknown"' "$j" 2>/dev/null); [ -n "$sub" ] || sub=unknown
    # ---- workflow progress from the AUTHORITATIVE state file (most-progressed session) ----
    chd="$work/.claude/claudehut"
    st=$(ls -t "$chd"/state/*.json 2>/dev/null | head -1)
    if [ -n "$st" ]; then
      wf=$(jq -c '{started:true, phase:(.phase//"?"), reuse_scan:(.reuse_scan//false), spec:((.spec_path//"")!=""), plan:((.plan_path//"")!=""), review:(.review//"pending"), completed:((.phase=="learn") and (.review=="pass"))}' "$st" 2>/dev/null)
    else
      wf='{"started":false,"phase":"none","reuse_scan":false,"spec":false,"plan":false,"review":"none","completed":false}'
    fi
    # ---- canonical-path artifact presence (detects the non-canonical-path defect) ----
    can=$(jq -nc --argjson r "$([ -n "$(ls "$chd"/tasks/*/reuse-scan.md "$chd"/reuse-scan-*.md 2>/dev/null)" ]&&echo true||echo false)" \
      --argjson s "$([ -n "$(ls "$chd"/tasks/*/spec.md "$chd"/specs/*.md 2>/dev/null)" ]&&echo true||echo false)" \
      --argjson p "$([ -n "$(ls "$chd"/tasks/*/plan.md "$chd"/plans/*.md 2>/dev/null)" ]&&echo true||echo false)" \
      --argjson l "$([ -s "$chd/learnings.jsonl" ]&&echo true||echo false)" \
      '{reuse_scan:$r,spec:$s,plan:$p,learnings:$l}')
    if [ -x "$d/oracle.sh" ]; then ( "$d/oracle.sh" "$work" >/dev/null 2>&1 ) && oracle=1 || oracle=0; else oracle=null; fi
    row=$(jq -nc --arg task "$t" --arg mode "$MODE" --arg sub "$sub" \
      --argjson iserr "$iserr" --argjson cost "$(num "$cost")" --argjson wall "$wall" \
      --argjson oracle "$oracle" --argjson wf "$wf" --argjson can "$can" --argjson init "$DO_INIT" \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{task:$task,mode:$mode,init_first:$init,terminal_status:$sub,is_error:$iserr,pass_at_1:$oracle,
        workflow:$wf,canonical_artifacts:$can,retries:0,cost_usd:$cost,wall_ms:$wall,ts:$ts}')
    printf '%s\n' "$row" >> "$RESULTS_DIR/${MODE}.jsonl"
    echo "  [$t #$i/$TRIALS] pass@1=$oracle  wf=$(echo "$wf"|jq -c '{phase,completed,reuse_scan}')  canon=$(echo "$can"|jq -c '[.reuse_scan,.spec,.plan,.learnings]')  cost=\$$cost term=$sub"
  done
done
echo "appended to $RESULTS_DIR/${MODE}.jsonl"
