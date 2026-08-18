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
# SKILL-F1: claudehut-workflow (119 lines) and claudehut-reviewer (90) each carry an explicit BYTE budget
# but fell through to the default LINE budget — 120 and 90 respectively. Sitting one line and zero lines
# from a limit nobody chose for them is an accident, not a decision: the next honest edit trips a budget
# that was never calibrated for that file. Both are now explicit, with the same modest headroom the other
# named entries have. This is not a re-growth allowance — the byte budgets are unchanged.
skill_budget() { case "$1" in review) echo 160 ;; implement) echo 210 ;; claudehut-workflow) echo 130 ;; discover) echo 115 ;; *) echo 120 ;; esac; }
agent_budget() { case "$1" in claudehut-implementer) echo 100 ;; claudehut-reuse-scanner) echo 105 ;; claudehut-reviewer) echo 95 ;; claudehut-planner|claudehut-brainstormer) echo 95 ;; *) echo 90 ;; esac; }
# Per-file BYTE budgets. Lines alone do not bound what the model reads: a commit titled "shrink the agent
# corpus" grew one agent by 1,933 B while its line count FELL by 9, because markdown table padding is free
# under `grep -c ''`. Bytes are what the context window pays for. Seeded ~15% above post-unpad sizes.
skill_bytes()  { case "$1" in review) echo 14000 ;; implement) echo 14500 ;; claudehut-workflow) echo 12000 ;; discover) echo 7500 ;; *) echo 6000 ;; esac; }
agent_bytes()  { case "$1" in claudehut-reuse-scanner|claudehut-planner) echo 7800 ;; claudehut-brainstormer) echo 7500 ;; claudehut-implementer|claudehut-reviewer) echo 7200 ;; *) echo 6000 ;; esac; }
# Provenance tags that belong in the research docs, not the always-loaded body. (M2: the `measured` pattern
# requires the audit FRACTION form `measured N/M` — so benign prose like "measured 3 outcomes" is NOT flagged.)
# SKILL-F12: widened. The old pattern missed BENCH-REPORT entirely, and required "Issue N" to sit
# immediately after an open paren — so "(WS-6, Issue 5)" sailed through. v0.N release tags are provenance
# too: an always-loaded body should state the rule, not when it changed. Benign "v2 API" and bare
# "measured latency" are deliberately NOT matched, and self-test (g) pins that.
PROV='EVAL-REPORT|BENCH-REPORT|RC-[0-9]|audit B\.[0-9]|Issue [0-9]|\(WS-[0-9]|v0\.[0-9]|measured [0-9]+/[0-9]+'

violations=0
flag() { echo "  FLAG - $1"; violations=$((violations+1)); }

lint_file() { # $1 path  $2 line-budget  $3 label  [$4 byte-budget]
  local f="$1" budget="$2" label="$3" bytebudget="${4:-0}" n b
  [ -f "$f" ] || return 0
  n="$(grep -c '' "$f" 2>/dev/null || echo 0)"
  [ "$n" -le "$budget" ] || flag "$label: $n lines > budget $budget (tighten or extract to references/)"
  if [ "$bytebudget" -gt 0 ]; then
    b="$(wc -c <"$f" 2>/dev/null | tr -d ' ')"; b="${b:-0}"
    [ "$b" -le "$bytebudget" ] || flag "$label: $b bytes > budget $bytebudget (tighten or extract to references/)"
  fi
  if grep -nEq "$PROV" "$f" 2>/dev/null; then
    flag "$label: provenance/audit tags in the always-loaded body (move to the research docs): $(grep -noE "$PROV" "$f" | head -3 | tr '\n' ' ')"
  fi
}

run_repo() {
  echo "== prompt-length + provenance lint =="
  local d n
  for d in "$ROOT"/skills/*/; do n="$(basename "$d")"; lint_file "$d/SKILL.md" "$(skill_budget "$n")" "skill:$n" "$(skill_bytes "$n")"; done
  for f in "$ROOT"/agents/*.md; do n="$(basename "$f" .md)"; lint_file "$f" "$(agent_budget "$n")" "agent:$n" "$(agent_bytes "$n")"; done
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

  # (d) within line budget but OVER byte budget -> >=1 violation (the padding loophole this closes)
  { for i in $(seq 1 10); do printf 'x%.0s' $(seq 1 300); echo; done; } > "$t/fat.md"
  violations=0; lint_file "$t/fat.md" 120 "test:fat" 1000 >/dev/null; local v_fat=$violations
  chk "lint_file flags a file within its LINE budget but over its BYTE budget" '[ "$v_fat" -ge 1 ]'

  # (e) byte budget of 0 disables the byte check (back-compat for callers passing no 4th arg)
  violations=0; lint_file "$t/fat.md" 120 "test:fat0" 0 >/dev/null; local v_fat0=$violations
  chk "lint_file skips the byte check when the byte budget is 0" '[ "$v_fat0" -eq 0 ]'

  # (g) SKILL-F12 guard, written BEFORE the regex was widened: benign product prose must survive. "v2 API"
  # and "measured latency" read like provenance to a careless pattern; only v0.N and the audit-fraction
  # form are provenance in this corpus.
  printf '# ok\nthe v2 API replaces v1; we measured latency under load and it held\n' > "$t/benign.md"
  violations=0; lint_file "$t/benign.md" 120 "test:benign" >/dev/null; local v_benign=$violations
  chk "lint_file does NOT flag benign product prose (\"v2 API\", \"measured latency\")" '[ "$v_benign" -eq 0 ]'

  # (h) the widened patterns must actually fire
  printf '# x\nsee BENCH-REPORT and (WS-6, Issue 5) from v0.8 WS-9\n' > "$t/prov2.md"
  violations=0; lint_file "$t/prov2.md" 120 "test:prov2" >/dev/null; local v_p2=$violations
  chk "lint_file flags BENCH-REPORT / (WS-N, Issue N) / v0.N provenance" '[ "$v_p2" -ge 1 ]'

  # (f) every skill/agent that has an explicit BYTE budget must also have an explicit LINE budget. A file
  # with one and not the other silently inherits a default calibrated for a different file — which is how
  # claudehut-workflow ended up one line from a limit nobody chose for it.
  local mismatched=0 n
  for n in review implement claudehut-workflow discover; do
    [ "$(skill_budget "$n")" = "120" ] && [ "$(skill_bytes "$n")" != "6000" ] && mismatched=$((mismatched+1))
  done
  for n in claudehut-reuse-scanner claudehut-planner claudehut-brainstormer claudehut-implementer claudehut-reviewer; do
    [ "$(agent_budget "$n")" = "90" ] && [ "$(agent_bytes "$n")" != "6000" ] && mismatched=$((mismatched+1))
  done
  chk "every file with an explicit byte budget also has an explicit line budget" '[ "$mismatched" -eq 0 ]'

  rm -rf "$t"; violations=0
  echo "  self-test: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
}

case "${1:-}" in
  --self-test) self_test ;;
  *) run_repo ;;
esac
