#!/usr/bin/env bash
# plugin-eval.sh — run the `claude plugin eval` suites (evals/suites/**) against THIS plugin (docs/v0.20 08 §4).
#
#   evals/plugin-eval.sh [--auth plan|api|auto] [--plugin-root DIR] [--keep-copy] [claude plugin eval options…]
#     --plugin-root DIR  evaluate ANOTHER tree (e.g. a baseline-0.12.6 worktree) with THIS tree's suites
#     e.g. evals/plugin-eval.sh --case end-refused-without-review --runs 1 --ablation none
#
# Why a wrapper:
#   - Bash in an eval run is sandboxed and cannot read $HOME, so the plugin under test is COPIED to $TMPDIR (outside
#     $HOME on macOS and Linux) — otherwise the agent cannot run bin/claudehut-state from the plugin root.
#   - Only evals/suites travels with the copy: the older oracles (evals/tasks/*/oracle.sh) never reach a run.
#   - --scaffold (cases seed fixture repos), --trust-plugin and the tool grants are always the same. --mocks off
#     starts the plugin's real MCP server (claudehut-kb, M3b): `mcp__*` is refused as a grant, so its tools are named.
# Auth (ADR K-17): `claude plugin eval` uses the same credentials as your sessions — plan = subscription login and
# its usage limits (default), api = ANTHROPIC_API_KEY. Results: evals/results/plugin-eval/<UTC timestamp>/.
# COSTS: every run is a model call on your plan or bill. Start with --runs 1 --ablation none on one case.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
AUTH=auto; KEEP=false; PROOT=""; pass=()
while [ $# -gt 0 ]; do
  case "$1" in
    --auth) AUTH="${2:-auto}"; shift 2 ;;
    --keep-copy) KEEP=true; shift ;;
    --plugin-root) PROOT="${2:-}"; shift 2 ;;
    *) pass+=("$1"); shift ;;
  esac
done
case "$AUTH" in plan|api|auto) ;; *) echo "auth must be plan|api|auto" >&2; exit 2 ;; esac
if [ "$AUTH" = auto ]; then [ -n "${ANTHROPIC_API_KEY:-}${ANTHROPIC_AUTH_TOKEN:-}" ] && AUTH=api || AUTH=plan; fi
if [ "$AUTH" = api ] && [ -z "${ANTHROPIC_API_KEY:-}${ANTHROPIC_AUTH_TOKEN:-}" ]; then
  echo "--auth api needs ANTHROPIC_API_KEY" >&2; exit 2
fi
if [ "$AUTH" = plan ]; then unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN; fi
command -v claude >/dev/null || { echo "claude not on PATH" >&2; exit 2; }
BASE="$(mktemp -d "${TMPDIR:-/tmp}/claudehut-eval.XXXXXX")"
case "$BASE" in "$HOME"/*) echo "warning: $BASE is under \$HOME — sandboxed Bash in the run may not read the plugin" >&2 ;; esac
COPY="$BASE/claudehut"; mkdir -p "$COPY"
SRC="${PROOT:-$ROOT}"; [ -d "$SRC/.claude-plugin" ] || { echo "not a plugin root: $SRC" >&2; exit 2; }
( cd "$SRC" && tar --exclude=./.git --exclude=./evals --exclude=./.claude --exclude=./.understand-anything -cf - . ) | ( cd "$COPY" && tar -xf - )
mkdir -p "$COPY/evals" && cp -R "$ROOT/evals/suites" "$COPY/evals/suites"
TS="$(date -u +%Y-%m-%dT%H-%M-%SZ)"; OUT="$ROOT/evals/results/plugin-eval/$TS"; mkdir -p "$OUT"
SHA="$(git -C "$SRC" rev-parse HEAD 2>/dev/null || echo unknown)"
DIRTY="$( [ -n "$(git -C "$SRC" status --porcelain -- . ':(exclude)evals/results' 2>/dev/null)" ] && echo true || echo false)"
printf '{"auth_mode":"%s","claude_version":"%s","plugin_version":"%s","source_sha":"%s","source_dirty":%s,"started":"%s"}\n' "$AUTH" \
  "$(claude --version 2>/dev/null | head -1)" "$(jq -r .version "$SRC/.claude-plugin/plugin.json" 2>/dev/null)" "$SHA" "$DIRTY" "$TS" > "$OUT/run-meta.json"
echo "plugin copy: $COPY   results: $OUT   auth: $AUTH"
( cd "$COPY" && claude plugin eval . --eval-dir evals/suites --scaffold --trust-plugin --no-publish \
    --output-dir "$OUT" --mocks off \
    --allow-tools Bash Write Edit mcp__plugin_claudehut_kb__kb_variation_points mcp__plugin_claudehut_kb__kb_patterns \
                  mcp__plugin_claudehut_kb__kb_brief "${pass[@]+"${pass[@]}"}" )
rc=$?
$KEEP || rm -rf "$BASE"
exit "$rc"
