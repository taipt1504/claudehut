#!/usr/bin/env bash
# Prompt-length + provenance lint (v0.8 WS-9, Issue 8: verbose skills/agents).
#
# HONESTLY SOFT: this is a COMMIT-TIME / CI auditor, NOT a runtime gate. Verbosity has no runtime primitive
# (a hook can't measure "is this prompt too long" before the model reads it). So this runs in pre-commit / CI
# to (a) cap each skill/agent body at a per-file budget — catching RE-GROWTH after the WS-9 trim — and
# (b) flag provenance/audit tags (RC-x, Issue-N, EVAL-REPORT, "measured N", audit B.x) that pollute the
# always-loaded hot path (their place is the research docs, not the prompt the agent reads every turn).
#
# Usage:
#   lint-prompt-length.sh              # lint the repo; exit 1 if any file is over budget or carries provenance
#   lint-prompt-length.sh --self-test  # prove the linter discriminates (synthetic over-budget + provenance) — free
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Per-file line budgets. Default by category; overrides for the legitimately-larger orchestration prompts.
skill_budget() { case "$1" in review) echo 160 ;; implement) echo 210 ;; *) echo 120 ;; esac; }
agent_budget() { case "$1" in claudehut-implementer) echo 100 ;; claudehut-reuse-scanner) echo 105 ;; *) echo 90 ;; esac; }
# Provenance tags that belong in the research docs, not the always-loaded body. (M2: the `measured` pattern
# requires the audit FRACTION form `measured N/M` — so benign prose like "measured 3 outcomes" is NOT flagged.)
PROV='EVAL-REPORT|RC-[0-9]|audit B\.[0-9]|\(Issue [0-9]|measured [0-9]+/[0-9]+'

violations=0
flag() { echo "  FLAG - $1"; violations=$((violations+1)); }

lint_file() { # $1 path  $2 budget  $3 label
  local f="$1" budget="$2" label="$3" n
  [ -f "$f" ] || return 0
  n="$(grep -c '' "$f" 2>/dev/null || echo 0)"
  [ "$n" -le "$budget" ] || flag "$label: $n lines > budget $budget (tighten or extract to references/)"
  if grep -nEq "$PROV" "$f" 2>/dev/null; then
    flag "$label: provenance/audit tags in the always-loaded body (move to the research docs): $(grep -noE "$PROV" "$f" | head -3 | tr '\n' ' ')"
  fi
}

run_repo() {
  echo "== prompt-length + provenance lint =="
  local d n
  for d in "$ROOT"/skills/*/; do n="$(basename "$d")"; lint_file "$d/SKILL.md" "$(skill_budget "$n")" "skill:$n"; done
  for f in "$ROOT"/agents/*.md; do n="$(basename "$f" .md)"; lint_file "$f" "$(agent_budget "$n")" "agent:$n"; done
  if [ "$violations" -eq 0 ]; then echo "  ok - all skill/agent bodies within budget + provenance-clean"; return 0; fi
  echo "  $violations violation(s)"; return 1
}

self_test() {
  # M1: drive the REAL lint_file against synthetic fixtures (not a re-implemented predicate) so a bug in
  # lint_file's budget lookup / comparison is actually caught. lint_file mutates the global `violations`.
  local t; t="$(mktemp -d)"; local pass=0 fail=0
  chk() { if eval "$2"; then pass=$((pass+1)); echo "  ok - $1"; else fail=$((fail+1)); echo "  FAIL - $1"; fi; }

  # (a) over-budget file → ≥1 violation
  { for i in $(seq 1 130); do echo "line $i"; done; } > "$t/over.md"
  violations=0; lint_file "$t/over.md" 120 "test:over" >/dev/null; local v_over=$violations
  chk "lint_file flags an over-budget file (130 > 120)" '[ "$v_over" -ge 1 ]'

  # (b) provenance tag (within length) → ≥1 violation
  printf '# a\nthis cites EVAL-REPORT #7 and (Issue 3) inline\n' > "$t/prov.md"
  violations=0; lint_file "$t/prov.md" 120 "test:prov" >/dev/null; local v_prov=$violations
  chk "lint_file flags a provenance tag in a within-budget file" '[ "$v_prov" -ge 1 ]'

  # (c) clean, within-budget file → 0 violations (no false positive)
  printf '# ok\nshort and clean\nmeasured 3 outcomes today\n' > "$t/clean.md"   # benign "measured 3" must NOT trip (M2)
  violations=0; lint_file "$t/clean.md" 120 "test:clean" >/dev/null; local v_clean=$violations
  chk "lint_file does NOT flag a clean file (incl. benign 'measured 3' — no false positive)" '[ "$v_clean" -eq 0 ]'

  rm -rf "$t"; violations=0
  echo "  self-test: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
}

case "${1:-}" in
  --self-test) self_test ;;
  *) run_repo ;;
esac
