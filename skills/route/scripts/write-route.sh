#!/usr/bin/env bash
# write-route.sh <quick|full> [--db-review] [--reason "..."]
# Persists the route decision as .claudehut/state/route-<task>.json (atomic
# same-dir tmp+mv). Maps the chosen profile → the ordered required phases the
# artifact-derived state machine will gate. Once written, claudehut_phase walks
# ONLY these phases — so this is the single point where pipeline depth is set.
set -euo pipefail

_find_plugin_root() {
  if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" ]]; then echo "$CLAUDE_PLUGIN_ROOT"; return; fi
  local d
  d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
  while [[ "$d" != "/" && -n "$d" ]]; do
    [[ -f "$d/.claude-plugin/plugin.json" ]] && { echo "$d"; return; }
    d="$(dirname "$d")"
  done
  echo "error: cannot locate plugin root" >&2; exit 1
}
PLUGIN_ROOT="$(_find_plugin_root)"
# shellcheck source=../../../hooks/lib/state.sh
source "$PLUGIN_ROOT/hooks/lib/state.sh"

PROFILE="${1:?usage: write-route.sh <quick|full> [--db-review] [--reason ...]}"
shift || true
DB="false"; REASON=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --db-review) DB="true"; shift ;;
    --reason)    REASON="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done

case "$PROFILE" in
  quick) PHASES='["build","loop"]' ;;
  full)  PHASES='["brainstorm","spec","plan","build","loop","learn"]' ;;
  *) echo "write-route.sh: profile must be quick|full (got: $PROFILE)" >&2; exit 2 ;;
esac

TASK_ID="$(claudehut_task_id)"
[[ "$TASK_ID" == "none" ]] && { echo "write-route.sh: no active task (on a default branch?)" >&2; exit 2; }
BRANCH="$(claudehut_branch)"
STATE_DIR="$(claudehut_state_dir)"
mkdir -p "$STATE_DIR"
OUT="$(claudehut_route_path "$TASK_ID")"
TMP="$OUT.tmp.$$"
jq -n --arg t "$TASK_ID" --arg b "$BRANCH" --arg p "$PROFILE" \
  --argjson phases "$PHASES" --argjson db "$DB" --arg r "$REASON" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{task_id:$t, branch:$b, profile:$p, phases:$phases, flags:{db_review:$db}, reason:$r, decided_at:$ts}' \
  > "$TMP" && mv "$TMP" "$OUT"
echo "route: $TASK_ID → $PROFILE (db_review=$DB) phases=$PHASES"
