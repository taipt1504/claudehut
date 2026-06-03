#!/usr/bin/env bash
# P7 — live #3-closure check (COSTS TOKENS; run only on an explicit budget go-ahead).
# Question: does a real `claude` session, told to init, actually INVOKE bin/claudehut-init and produce
# the project plane? (init-tests.sh proved EXECUTION; this proves INVOCATION — #3's real failure mode.)
# Init-only, N trials, stream-json transcript captured + inspected. #3 CLOSED iff plane=5/5 in ALL trials.
# Run: evals/p7-init.sh [N]   (default N=3)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
N="${1:-3}"
FIXTURE="$ROOT/evals/tasks/clean-first-run/repo"
RESULTS="$ROOT/evals/results"; mkdir -p "$RESULTS"
command -v claude >/dev/null || { echo "claude not on PATH" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq not on PATH" >&2; exit 2; }
num() { case "$1" in ''|*[!0-9.]*) echo 0 ;; *) echo "$1" ;; esac; }

# answer-key-leak guard: sanitized plugin copy
SAN="$(mktemp -d)/plugin"; cp -R "$ROOT" "$SAN"; rm -rf "$SAN/evals" "$SAN/docs" "$SAN/.git"
echo "P7: $N init-only trials on clean-first-run (sanitized plugin). Plane must appear in ALL trials to close #3."

pass=0
for ((i=1;i<=N;i++)); do
  work="$(mktemp -d)/work"; mkdir -p "$work"; cp -R "$FIXTURE/." "$work/"
  ( cd "$work" && git init -q && git add -A && git commit -qm base >/dev/null 2>&1 )
  strm="$work/.init.stream.jsonl"
  ( cd "$work" && CLAUDE_PROJECT_DIR="$work" CLAUDE_PLUGIN_ROOT="$SAN" \
      claude --print --plugin-dir "$SAN" --output-format stream-json --verbose --max-budget-usd 1.50 \
      "Bootstrap this project for ClaudeHut by running its init." < /dev/null ) > "$strm" 2>"$work/.err" || true
  chd="$work/.claude/claudehut"
  plane=0; for f in MEMORY.md PROJECT.md LANGUAGE.md architecture.md reuse-index.json; do [ -f "$chd/$f" ] && plane=$((plane+1)); done
  init_seen=0; grep -q '"name":"Skill"' "$strm" 2>/dev/null && grep -q 'claudehut-init' "$strm" 2>/dev/null && init_seen=1
  script_ran=0; grep -q 'bin/claudehut-init' "$strm" 2>/dev/null && script_ran=1
  wrongdir=0; [ -d "$work/.claudehut" ] && wrongdir=1
  rules=$(find "$work/.claude/rules" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
  imp=$(grep -c 'project-adaptive memory' "$work/CLAUDE.md" 2>/dev/null || echo 0)
  cost=$(num "$(grep '^{' "$strm" 2>/dev/null | jq -rc 'select(.type=="result")|.total_cost_usd // 0' 2>/dev/null | tail -1)")
  verdict=FAIL; { [ "$plane" = 5 ] && [ "$wrongdir" = 0 ]; } && { verdict=PASS; pass=$((pass+1)); }
  echo "  [trial $i/$N] plane=$plane/5  skill_invoked=$init_seen  script_ran=$script_ran  wrongdir=$wrongdir  rules=${rules:-0}  import=$imp  cost=\$$cost  -> $verdict"
  echo "      transcript: $strm"
  row=$(jq -nc --arg t clean-first-run --argjson plane "$plane" --argjson sr "$script_ran" --argjson wd "$wrongdir" \
    --argjson rules "$(num "$rules")" --argjson cost "$cost" --arg v "$verdict" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{task:$t,mode:"init-p7",plane:$plane,script_ran:$sr,wrongdir:$wd,rules:$rules,cost_usd:$cost,verdict:$v,ts:$ts}')
  printf '%s\n' "$row" >> "$RESULTS/claudehut.jsonl"
done
echo
echo "P7 RESULT: $pass/$N trials produced the full plane (5/5)."
if [ "$pass" = "$N" ]; then echo "=> #3 CLOSED (live invocation reliably produces the plane). Update EVAL-REPORT #3 -> FIXED."
else echo "=> #3 NOT closed — invocation flaky/absent. Apply the FALLBACK (bootstrap.sh runs bin/claudehut-init when .claude/claudehut absent), then re-run P7."; fi
[ "$pass" = "$N" ]
