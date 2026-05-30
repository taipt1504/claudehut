#!/usr/bin/env bash
# budget-gate.sh <spent> <n_workers> <max_pool> <max_worker> <floor>
#
# Phase 5.1 — PURE worker-pool budget gate (no side effects, no model calls).
# Decides, at a group boundary (no workers in flight → race-free), whether the
# worker pool can fund the next group. Echoes exactly one of:
#   launch <worker_budget_usd>   proceed; cap each worker at this --max-budget-usd
#   launch                       proceed UNLIMITED (no per-worker cap)
#   skip <reason>                pool can't fund it; caller writes budget-breach.json + exit 3
#
# HONEST SCOPE: this governs only the build worker POOL (sum of *.cost). It does
# NOT see the orchestrator main-session spend (the documented ~$1 ceremony death)
# — that is capped at the top-level `claude --max-budget-usd` (evals/run.sh). A
# tight per-worker cap would recreate mid-task budget-kill, so max_worker is a
# generous backstop, not the primary governor.
#
# Backward compat: max_pool empty or 0 → UNLIMITED (every existing project with no
# budget.* config keys is unaffected). POSIX awk arithmetic; bash 3.2 safe.
set -uo pipefail

SPENT="${1:-0}"
N="${2:-1}"
MAX_POOL="${3:-}"
MAX_WORKER="${4:-}"
FLOOR="${5:-0.50}"

case "$MAX_POOL" in
  ''|0|0.0|0.00) echo "launch "; exit 0 ;;   # unlimited
esac

awk -v spent="$SPENT" -v n="$N" -v pool="$MAX_POOL" -v maxw="$MAX_WORKER" -v floor="$FLOOR" 'BEGIN{
  if (n < 1) n = 1
  remaining = pool - spent
  per = remaining / n
  if (per < floor) {
    printf "skip pool=%.2f spent=%.2f remaining=%.2f per_worker=%.2f < floor=%.2f for %d task(s)\n", pool, spent, remaining, per, floor, n
    exit 0
  }
  wb = per
  if (maxw != "" && maxw+0 > 0 && wb > maxw+0) wb = maxw+0
  printf "launch %.2f\n", wb
}'
