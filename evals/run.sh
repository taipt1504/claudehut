#!/usr/bin/env bash
# Scenario runner + live benchmark for ClaudeHut.
# Dry-run by DEFAULT (free). --live drives real `claude --print` (COSTS TOKENS). --trials N repeats.
# Usage: evals/run.sh [--live] [--trials N] [--mode claudehut|baseline|both] [--auth plan|api|auto] [--no-init] [task ...]
# Env:   CLAUDEHUT_EVAL_BUDGET (default 12.00; a per-task evals/tasks/<t>/budget file wins)  CLAUDEHUT_EVAL_MODEL (default sonnet)
#
# 0.12.7 (docs/v0.20 08 §4.1, ADR K-13/K-17):
#   --mode both   runs the no-plugin baseline arm next to the claudehut arm for every trial (Δ in score.sh)
#   --auth        plan = `claude --print` with your subscription login (default when no API key; counts against
#                 the plan's usage limits; your own hooks/plugins load, so rows carry env_profile); api = adds
#                 --bare (needs ANTHROPIC_API_KEY or apiKeyHelper; reproducible); auto = api when a key is set.
#   rows carry auth_mode + claude_version; a run killed by the budget cap is `aborted` and NOT scored (pass_at_1
#   null) — 21/36 June rows were budget kills counted as fails. is_error is read correctly (`.is_error // true`
#   turned every false into true).
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
LIVE=false; TRIALS=1; MODE=claudehut; DO_INIT=true; AUTH=auto; args=()
while [ $# -gt 0 ]; do case "$1" in
  --live) LIVE=true; shift ;;
  --trials) TRIALS="${2:-1}"; shift 2 ;;
  --mode) MODE="${2:-claudehut}"; shift 2 ;;
  --auth) AUTH="${2:-auto}"; shift 2 ;;
  --no-init) DO_INIT=false; shift ;;
  *) args+=("$1"); shift ;;
esac; done
case "$MODE" in claudehut|baseline|both) ;; *) echo "mode must be claudehut|baseline|both" >&2; exit 2 ;; esac
case "$AUTH" in plan|api|auto) ;; *) echo "auth must be plan|api|auto" >&2; exit 2 ;; esac
if [ "$AUTH" = auto ]; then
  if [ -n "${ANTHROPIC_API_KEY:-}${ANTHROPIC_AUTH_TOKEN:-}" ]; then AUTH=api; else AUTH=plan; fi
fi
[ "$AUTH" = api ] && [ -z "${ANTHROPIC_API_KEY:-}${ANTHROPIC_AUTH_TOKEN:-}" ] && { echo "--auth api needs ANTHROPIC_API_KEY (bare mode never reads the subscription login)" >&2; exit 2; }
BARE=(); [ "$AUTH" = api ] && BARE=(--bare)
OFF_PLUGINS='[]'
if [ "$AUTH" = plan ]; then
  OFF_PLUGINS="$(jq -c '[(.enabledPlugins // {}) | to_entries[] | select(.value == true) | .key]' "$HOME/.claude/settings.json" 2>/dev/null || echo '[]')"
  [ -n "$OFF_PLUGINS" ] || OFF_PLUGINS='[]'
fi
# NB: "${args[@]}" on an empty array under `set -u` is an unbound-variable error on bash 3.2
# (macOS default) — guard by length before expanding.
sel=(); [ ${#args[@]} -gt 0 ] && sel=("${args[@]}")
[ ${#sel[@]} -eq 0 ] && sel=($(ls "$TASKS_DIR"))
BUDGET_DEFAULT="${CLAUDEHUT_EVAL_BUDGET:-12.00}"; MODEL="${CLAUDEHUT_EVAL_MODEL:-sonnet}"
mkdir -p "$RESULTS_DIR"

if ! $LIVE; then
  echo "(dry run — pass --live to drive Claude Code; costs tokens/plan quota). mode=$MODE auth=$AUTH trials=$TRIALS init=$DO_INIT tasks: ${sel[*]}"
  exit 0
fi
command -v claude >/dev/null || { echo "claude not on PATH" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq not on PATH" >&2; exit 2; }
. "$ROOT/evals/lib/artifact-checks.sh"   # resolve_task_json
num() { case "$1" in ''|*[!0-9.]*) echo 0 ;; *) echo "$1" ;; esac; }

SAN=""
CVER="$(claude --version 2>/dev/null | head -1)"
ENVP="$(bash "$ROOT/bin/claudehut-kernel" probe --project "$ROOT" 2>/dev/null | jq -c '{auth_mode, rewriters, hooks:[.bash_hooks[]?.command]}' 2>/dev/null || echo '{}')"
[ -n "$ENVP" ] || ENVP='{}'
if [ "$MODE" != baseline ]; then SAN="$(mktemp -d)/plugin"; cp -R "$ROOT" "$SAN"; rm -rf "$SAN/evals" "$SAN/docs" "$SAN/.git"; fi

for t in "${sel[@]}"; do
  d="$TASKS_DIR/$t"; [ -d "$d/repo" ] || { echo "skip: no fixture $t"; continue; }
  # A task whose oracle asserts removed v0.11 behavior is skipped with its reason, not scored as a silent FAIL.
  [ -f "$d/STALE" ] && { echo "skip: $t is stale — $(head -1 "$d/STALE")"; continue; }
  prompt="$(cat "$d/task.md")"
  BUDGET="$BUDGET_DEFAULT"; [ -f "$d/budget" ] && BUDGET="$(tr -d ' \n' < "$d/budget")"
  ARMS=("$MODE"); [ "$MODE" = both ] && ARMS=(claudehut baseline)
  for ((i=1;i<=TRIALS;i++)); do
  for ARM in "${ARMS[@]}"; do
    work="$(mktemp -d)/work"; mkdir -p "$work"; cp -R "$d/repo/." "$work/"
    # CC ≥2.1.x headless treats .claude/** edits as "sensitive" — acceptEdits does NOT auto-approve them,
    # which deadlocks the workflow (artifacts live under .claude/claudehut/). Allow them explicitly.
    mkdir -p "$work/.claude"
    # plan auth (no --bare) loads YOUR installed plugins: switch every user-enabled one off in the workspace so the
    # baseline arm really has no plugin and the claudehut arm loads only the --plugin-dir copy.
    jq -n --argjson off "$OFF_PLUGINS" '{permissions:{allow:["Write(.claude/claudehut/**)","Edit(.claude/claudehut/**)","Write(./.claude/claudehut/**)","Edit(./.claude/claudehut/**)"]},
      enabledPlugins: ($off | map({(.): false}) | add // {})}' > "$work/.claude/settings.json"
    ( cd "$work" && git init -q && git add -A && git commit -qm base >/dev/null 2>&1 )
    j="$work/.eval.json"; icost=0
    start=$(date +%s)
    if [ "$ARM" = baseline ]; then
      ( cd "$work" && claude ${BARE[@]+"${BARE[@]}"} --print --output-format json --model "$MODEL" --max-budget-usd "$BUDGET" \
          --dangerously-skip-permissions "$prompt" < /dev/null ) > "$j" 2>"$work/.err" || true
    else
      if $DO_INIT; then
        ( cd "$work" && CLAUDE_PROJECT_DIR="$work" CLAUDE_PLUGIN_ROOT="$SAN" \
            claude ${BARE[@]+"${BARE[@]}"} --print --plugin-dir "$SAN" --output-format json --model "$MODEL" --max-budget-usd 1.20 \
            --dangerously-skip-permissions "Bootstrap this project for ClaudeHut: run claudehut-init to detect the stack and generate the project index, memory, and path-scoped rules under .claude/claudehut/." < /dev/null ) \
            > "$work/.init.json" 2>"$work/.init.err" || true
        icost=$(num "$(jq -r '.total_cost_usd // 0' "$work/.init.json" 2>/dev/null)")
      fi
      full="$prompt

This project uses the ClaudeHut plugin; its 7-phase workflow is injected at session start. Drive the ClaudeHut workflow to completion: triage the complexity tier FIRST (Phase 0) AND the task profile (Phase 0b), open the task with claudehut-state start --route light|full --profile <p> --slug <s>, then run exactly that tier's phases, writing all workflow artifacts under .claude/claudehut/. Complete the task.

NON-INTERACTIVE (-p) RUN: there is no human to answer questions. At every approval gate (Spec, Plan), DO NOT end your turn waiting for approval — take the documented non-interactive path: proceed with your draft, record the 'approval: non-interactive run — proceeded with draft' marker, and continue. Drive all the way through Implement → Review → Learn until review=pass, the Learn pass has run, and the task is closed with claudehut-state end --status done. Never stop at a question."
      ( cd "$work" && CLAUDE_PROJECT_DIR="$work" CLAUDE_PLUGIN_ROOT="$SAN" \
          claude ${BARE[@]+"${BARE[@]}"} --print --plugin-dir "$SAN" --output-format json --model "$MODEL" --max-budget-usd "$BUDGET" \
          --dangerously-skip-permissions "$full" < /dev/null ) > "$j" 2>"$work/.err" || true
    fi
    end=$(date +%s); wall=$(( (end - start) * 1000 ))
    tcost=$(num "$(jq -r '.total_cost_usd // 0' "$j" 2>/dev/null)")
    cost=$(echo "$icost + $tcost" | bc 2>/dev/null || echo "$tcost")
    # `.is_error // true` is a jq trap: `//` also replaces false, so every row read true. Absent → true.
    iserr=$(jq -r 'if type=="object" and has("is_error") then .is_error else true end' "$j" 2>/dev/null); [ "$iserr" = true ] || [ "$iserr" = false ] || iserr=true
    sub=$(jq -r '.subtype // "unknown"' "$j" 2>/dev/null); [ -n "$sub" ] || sub=unknown
    # ---- workflow progress from the AUTHORITATIVE state file (most-progressed session) ----
    chd="$work/.claude/claudehut"
    # schema 2: state/<sid>.json is a pointer; the workflow fields live in tasks/<id>/task.json
    st=$(resolve_task_json "$chd")
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
    aborted=false
    case "$sub" in error_max_budget_usd|error_max_turns) aborted=true ;; esac   # a crash (error_during_execution) is scored
    if $aborted; then oracle=null   # a killed run says nothing about the plugin: not scored
    elif [ -x "$d/oracle.sh" ]; then ( "$d/oracle.sh" "$work" >/dev/null 2>&1 ) && oracle=1 || oracle=0; else oracle=null; fi
    row=$(jq -nc --arg task "$t" --arg mode "$ARM" --arg sub "$sub" --argjson aborted "$aborted" \
      --arg auth "$AUTH" --arg cver "$CVER" --argjson envp "$ENVP" --argjson budget "$(num "$BUDGET")" \
      --argjson iserr "$iserr" --argjson cost "$(num "$cost")" --argjson wall "$wall" \
      --argjson oracle "$oracle" --argjson wf "$wf" --argjson can "$can" --argjson init "$DO_INIT" \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{task:$task,mode:$mode,auth_mode:$auth,claude_version:$cver,env_profile:$envp,budget_usd:$budget,
        init_first:$init,terminal_status:$sub,aborted:$aborted,is_error:$iserr,pass_at_1:$oracle,
        workflow:$wf,canonical_artifacts:$can,retries:0,cost_usd:$cost,wall_ms:$wall,ts:$ts}')
    printf '%s\n' "$row" >> "$RESULTS_DIR/${ARM}.jsonl"
    echo "  [$t #$i/$TRIALS $ARM/$AUTH] pass@1=$oracle  wf=$(echo "$wf"|jq -c '{phase,completed,reuse_scan}')  canon=$(echo "$can"|jq -c '[.reuse_scan,.spec,.plan,.learnings]')  cost=\$$cost term=$sub"
  done
  done
done
echo "appended to $RESULTS_DIR/{claudehut,baseline}.jsonl (arms: $MODE, auth: $AUTH)"
