#!/usr/bin/env bash
# sum-worker-cost.sh <log-dir>
#
# Phase 5.1 — echoes the cumulative build-worker spend for THIS run (a bare float):
# the sum of every `*.cost` in <log-dir>, which the budget gate compares against
# the pool cap.
#
# SEMANTICS (defined, not silent): counts EVERY worker .cost — including FAILED,
# BUDGET-KILLED, and loop-RETRIED attempts — because each one spent REAL money. The
# pool cap governs real cumulative $ out, not the value of work that stuck. A
# loop-retry (run-parallel-group re-invoked → fresh PID → new .cost files, prior
# ones still present) therefore adds to the total: you genuinely spent on both
# attempts, so the gate halts sooner — correct for "don't blow the budget".
#
# Robust to a no-match glob (a clean first group has no .cost): the per-file
# `[[ -f ]]` guard skips the literal glob → total stays 0 (score.sh's pattern;
# avoids the bare `awk *.cost` that errors + can emit a malformed value).
set -uo pipefail

LOG_DIR="${1:?usage: sum-worker-cost.sh <log-dir>}"
total=0
for c in "$LOG_DIR"/*.cost; do
  [[ -f "$c" ]] || continue
  total="$(awk -v a="$total" -v b="$(cat "$c" 2>/dev/null || echo 0)" 'BEGIN{printf "%.6f", a + (b + 0)}')"
done
printf '%.6f\n' "$total"
