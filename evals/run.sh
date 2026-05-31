#!/usr/bin/env bash
# run.sh <task-name> <mode>
#   mode: baseline   — plain Claude Code (no plugin), one prompt
#         claudehut  — the full ClaudeHut pipeline (--plugin-dir, phases drive themselves)
#
# OPT-IN, real-Claude, COSTS TOKENS (not in CI). Mirrors tests/e2e/run-real-claude.sh.
# Copies the fixture's repo/ to a throwaway workdir, runs the task there with a
# cost cap, then scores with the HELD-OUT oracle and appends a metrics row to
# evals/results/<mode>.jsonl.
#
# Env: CLAUDEHUT_EVAL_BUDGET (default 2.00 USD), CLAUDEHUT_EVAL_MODEL (default sonnet).
set -uo pipefail

TASK="${1:?usage: run.sh <task-name> <baseline|claudehut>}"
MODE="${2:?usage: run.sh <task-name> <baseline|claudehut>}"
case "$MODE" in baseline|claudehut|sdk) ;; *) echo "mode must be baseline|claudehut|sdk" >&2; exit 2 ;; esac

EVALS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
PLUGIN_ROOT="$(cd "$EVALS_DIR/.." && pwd -P)"
TASK_DIR="$EVALS_DIR/tasks/$TASK"
[[ -d "$TASK_DIR/repo" ]] || { echo "no fixture repo: $TASK_DIR/repo" >&2; exit 2; }
command -v claude >/dev/null || { echo "claude CLI not in PATH" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq not in PATH" >&2; exit 2; }

BUDGET="${CLAUDEHUT_EVAL_BUDGET:-2.00}"
MODEL="${CLAUDEHUT_EVAL_MODEL:-sonnet}"
PROMPT="$(cat "$TASK_DIR/task.md")"

WORK="$(mktemp -d)/work"; mkdir -p "$WORK"
cp -R "$TASK_DIR/repo/." "$WORK/"
RESULTS="$EVALS_DIR/results/${MODE}.jsonl"
mkdir -p "$EVALS_DIR/results"
JSON_OUT="$WORK/.eval-claude.json"

echo "eval: task=$TASK mode=$MODE budget=\$$BUDGET model=$MODEL"
echo "workdir: $WORK"

_start="$(date +%s)"
if [[ "$MODE" == "baseline" ]]; then
  ( cd "$WORK" && git init -q && git checkout -q -b eval/baseline 2>/dev/null && git add -A && git commit -qm base )
  ( cd "$WORK" && claude --print --output-format json --model "$MODEL" --max-budget-usd "$BUDGET" \
      --permission-mode acceptEdits "$PROMPT" ) > "$JSON_OUT" 2>"$WORK/.eval-err.txt" || true
else
  # claudehut mode: scaffold minimal project state + a feature branch, then let the
  # plugin's orchestrator drive the phases headlessly.
  ( cd "$WORK" && git init -q && git checkout -q -b "feature/eval-$TASK" 2>/dev/null )
  mkdir -p "$WORK/.claudehut/"{specs,plans,memory,findings,reuse-scans,logs} "$WORK/.claude"
  printf -- '- web: mvc\n- orm: jpa\n- db: postgresql\n' > "$WORK/.claudehut/memory/stack-signals.md"
  # Optional Phase-4 seed: start the run with a learnings corpus so JIT retrieval
  # (4.1) has something to surface. Without it a fresh project has no learnings and
  # retrieval is a no-op stub — so the $ real-run A/B for Phase 4 needs this seed.
  if [[ -n "${CLAUDEHUT_EVAL_SEED_LEARNINGS:-}" && -f "${CLAUDEHUT_EVAL_SEED_LEARNINGS}" ]]; then
    cp "$CLAUDEHUT_EVAL_SEED_LEARNINGS" "$WORK/.claudehut/memory/learnings.jsonl"
    echo "seeded learnings: $(wc -l < "$WORK/.claudehut/memory/learnings.jsonl" | tr -d ' ') entries from $CLAUDEHUT_EVAL_SEED_LEARNINGS"
  fi
  printf '{"enabledPlugins":{"claudehut":true}}\n' > "$WORK/.claude/settings.json"
  printf '.claudehut/\n' > "$WORK/.gitignore"
  ( cd "$WORK" && git add -A && git commit -qm base )
  # EVAL-INTEGRITY (answer-key leak): the agent runs `--print` with Bash and reads
  # $CLAUDE_PLUGIN_ROOT. If that's the real repo, it can `cat` the HELD-OUT oracle,
  # meta.json, and tests/run-all.sh — i.e. the answer key — confounding pass@1.
  # (Observed: an unseeded slugify run read the oracle from $CLAUDE_PLUGIN_ROOT and
  # used the convention with no seed.) So point --plugin-dir + CLAUDE_PLUGIN_ROOT at
  # a SANITIZED copy with evals/tests/docs/.git stripped. The plugin RUNTIME needs
  # only .claude-plugin/, hooks/, skills/, agents/, bin/ — all kept.
  PLUGIN_SANITIZED="$(mktemp -d)/plugin"
  cp -R "$PLUGIN_ROOT" "$PLUGIN_SANITIZED"
  rm -rf "$PLUGIN_SANITIZED/evals" "$PLUGIN_SANITIZED/tests" "$PLUGIN_SANITIZED/docs" \
         "$PLUGIN_SANITIZED/.git" "$PLUGIN_SANITIZED/sdk/node_modules"
  # MCP servers (context7/github/memory/postgres/sequential-thinking) BLOCK on startup
  # in this headless, key-less, non-interactive harness — observed: claude --print
  # hangs ~80min then is_error=true, $0, pass@1=0. They are optional enrichment, not
  # needed for the eval tasks, and the sdk arm runs without them — so neutralize MCP
  # for BOTH arms (fair, headless-safe comparison; MCP behavior is out of eval scope).
  printf '{"mcpServers":{}}\n' > "$PLUGIN_SANITIZED/.mcp.json"
  CH_PROMPT="$PROMPT

Follow the ClaudeHut workflow per the SessionStart dispatch contract. FIRST triage the task depth via /claudehut:route (it picks quick or full); then drive ONLY the phases the recorded route declares, through to done. Do not force phases the route did not select. Complete the task."
  if [[ "$MODE" == "claudehut" ]]; then
    ( cd "$WORK" && CLAUDE_PROJECT_DIR="$WORK" CLAUDE_PLUGIN_ROOT="$PLUGIN_SANITIZED" \
        claude --print --plugin-dir "$PLUGIN_SANITIZED" --output-format json --model "$MODEL" \
        --max-budget-usd "$BUDGET" --permission-mode acceptEdits "$CH_PROMPT" ) \
        > "$JSON_OUT" 2>"$WORK/.eval-err.txt" || true
  else
    # sdk arm (Phase 7.1): the programmatic orchestrator drives the SAME scaffolded
    # phases and emits a `claude --print`-shaped envelope to CLAUDEHUT_ORCH_JSON_OUT,
    # so score.sh grades it identically to the bash arms. Needs node + a one-time
    # `cd sdk && npm install`. The agent's CLAUDE_PLUGIN_ROOT is the sanitized copy
    # (same answer-key-leak guard as claudehut mode).
    command -v node >/dev/null || { echo "node not in PATH (sdk arm)" >&2; exit 2; }
    [[ -d "$PLUGIN_ROOT/sdk/node_modules" ]] || { echo "sdk deps missing — run: (cd '$PLUGIN_ROOT/sdk' && npm install)" >&2; exit 2; }
    ( cd "$WORK" && CLAUDE_PROJECT_DIR="$WORK" CLAUDE_PLUGIN_ROOT="$PLUGIN_SANITIZED" \
        CLAUDEHUT_ORCH_JSON_OUT="$JSON_OUT" CLAUDEHUT_MAX_POOL_USD="$BUDGET" \
        node "$PLUGIN_ROOT/sdk/orchestrator.mjs" "$CH_PROMPT" ) > "$WORK/.orch.log" 2>&1 || true
  fi
fi
_end="$(date +%s)"
WALL_MS=$(( (_end - _start) * 1000 ))

echo "--- run finished (${WALL_MS}ms). Scoring with held-out oracle... ---"
ROW="$(bash "$EVALS_DIR/score.sh" "$TASK" "$WORK" --claude-json "$JSON_OUT" --wall-ms "$WALL_MS" --mode "$MODE")"
# stamp ts at append time (scripts can't call Date.now; use shell date here)
ROW="$(printf '%s' "$ROW" | jq -c --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '. + {ts:$ts}')"
printf '%s\n' "$ROW" >> "$RESULTS"
echo "$ROW" | jq .
echo "--- appended to $RESULTS ---"
echo "workdir kept for inspection: $WORK"
