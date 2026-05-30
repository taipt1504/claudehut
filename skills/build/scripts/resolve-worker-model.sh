#!/usr/bin/env bash
# resolve-worker-model.sh <plugin_root> <main_repo>
#
# Phase 5.3 — three-tier worker-model resolution. Prints the resolved model id.
#   Tier 1: CLAUDEHUT_WORKER_MODEL env  (dev/CI override)
#   Tier 2: claudehut-state config agents.builder_model  (project config)
#   Tier 3: sonnet  (default)
#
# NOTE the namespace is agents.builder_model (verified in
# claudehut-config.template.json) — phase.builder_model would jq-miss and silently
# no-op. A bash-3.2 `case` guard validates the id (an unknown id crashes the
# `claude` session launch) → warn to stderr + fall back to sonnet. NO model calls.
set -uo pipefail

PLUGIN_ROOT="${1:-}"
MAIN_REPO="${2:-}"

model=""
if [[ -n "${CLAUDEHUT_WORKER_MODEL:-}" ]]; then
  model="$CLAUDEHUT_WORKER_MODEL"
elif [[ -n "$PLUGIN_ROOT" && -n "$MAIN_REPO" && -x "$PLUGIN_ROOT/bin/claudehut-state" ]]; then
  model="$(CLAUDE_PROJECT_DIR="$MAIN_REPO" "$PLUGIN_ROOT/bin/claudehut-state" config agents.builder_model 2>/dev/null || true)"
fi
model="${model:-sonnet}"

case "$model" in
  opus|sonnet|haiku|claude-opus-4-*|claude-sonnet-4-*|claude-haiku-4-*) ;;
  *)
    echo "warn: unrecognized worker model '$model' (agents.builder_model) — falling back to sonnet" >&2
    model="sonnet"
    ;;
esac
printf '%s\n' "$model"
