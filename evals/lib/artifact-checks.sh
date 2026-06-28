#!/usr/bin/env bash
# Artifact oracles for ClaudeHut (v0.7 benchmark P0 fix). The conformance grep-checks prove an INSTRUCTION
# is written; these parse a PRODUCED artifact and fail on VACUOUS output — converting the Cognition-plane
# guarantees from textual-only to regression-catchable. Same philosophy as merge-learnings-tests (the one
# plane already done right): assert on real outcomes, not keyword presence.
#
# Sourceable: `. evals/lib/artifact-checks.sh`. Each check echoes findings and returns 0 (clean) / 1 (violation).
# Used by (a) evals/artifact-oracle-tests.sh — a FREE self-test that feeds good+bad samples and asserts the
# oracle DISCRIMINATES (proving the oracle itself works), and (b) live task oracle.sh files that run the
# checks on artifacts a real agent produced.

# ── trim helper
_trim() { printf '%s' "$1" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'; }

# ── R1/R2: reuse-scan must carry NON-VACUOUS Fit/Impact (semantic judgment, not "all 5s").
# Fails if: an adopt/extend/framework row has Fit not in 1-5 or empty Impact; a Fit<=2 row with no Evidence
# section; or >=3 scored rows all identical (the "vacuously filled" signal the advisor named).
check_reuse_scan_rigor() {
  local f="$1" fails=0 scored=0 distinct vals=""
  [ -f "$f" ] || { echo "FAIL reuse-scan: file not found: $f"; return 1; }
  local has_evidence=0; grep -qE '^##[[:space:]]+Evidence' "$f" && has_evidence=1
  # iterate the Summary table data rows (skip header row containing "Decision" and separator rows)
  while IFS= read -r row; do
    case "$row" in *Decision*|*'---'*) continue ;; esac
    local dec fit imp dim
    dim="$(_trim "$(printf '%s' "$row" | awk -F'|' '{print $2}')")"
    dec="$(_trim "$(printf '%s' "$row" | awk -F'|' '{print $4}')")"
    fit="$(_trim "$(printf '%s' "$row" | awk -F'|' '{print $5}')")"
    imp="$(_trim "$(printf '%s' "$row" | awk -F'|' '{print $6}')")"
    [ -n "$dec" ] || continue
    local decw="${dec%% *}"
    case "$decw" in
      adopt|extend|framework)
        if ! printf '%s' "$fit" | grep -qE '^[1-5]$'; then
          echo "FAIL reuse-scan: row '$dim' decision=$decw but Fit not 1-5 (got '$fit') — no semantic judgment"; fails=$((fails+1))
        else
          scored=$((scored+1)); vals="$vals $fit"
          if { [ "$fit" = "1" ] || [ "$fit" = "2" ]; } && [ "$has_evidence" = 0 ]; then
            echo "FAIL reuse-scan: row '$dim' Fit=$fit (low) but no ## Evidence section justifying it"; fails=$((fails+1))
          fi
        fi
        if [ -z "$imp" ] || [ "$imp" = "-" ]; then
          echo "FAIL reuse-scan: row '$dim' decision=$decw but Impact empty — blast-radius not assessed"; fails=$((fails+1))
        fi
        ;;
    esac
  done < <(grep -E '^\|' "$f")
  # vacuity: >=3 scored rows all identical Fit = vacuously filled column.
  # Count distinct shell-INDEPENDENTLY (tr space→newline) — `printf '%s\n' $vals` relies on word-splitting,
  # which bash does but zsh/POSIX-strict shells do NOT (they'd see one arg → distinct=1 → false-reject a
  # varied scan). tr makes the count correct under any shell. (re-audit hardening.)
  distinct="$(printf '%s' "$vals" | tr ' ' '\n' | sed '/^$/d' | sort -u | grep -c . || true)"
  if [ "$scored" -ge 3 ] && [ "$distinct" = "1" ]; then
    echo "FAIL reuse-scan: $scored adopt/extend/framework rows ALL share Fit$vals — vacuous (no real judgment)"; fails=$((fails+1))
  fi
  [ "$fails" -eq 0 ] && echo "ok reuse-scan: $scored scored rows, Fit varied, Impact present, low-Fit justified"
  [ "$fails" -eq 0 ]
}

# ── R4: plan must carry the HOW (§3 Implementation Flow) and NO placeholder sketches.
check_plan_no_placeholder() {
  local f="$1" fails=0
  [ -f "$f" ] || { echo "FAIL plan: file not found: $f"; return 1; }
  grep -qE '^##[[:space:]]+3\.[[:space:]]+Implementation Flow' "$f" \
    || { echo "FAIL plan: missing '## 3. Implementation Flow' (the HOW a reviewer reads)"; fails=$((fails+1)); }
  # placeholder tokens that mean "not actually designed" (word-based; avoid '...' which collides with paths)
  local bad; bad="$(grep -niE 'TBD|implement (the )?logic|add error handling|add validation logic|handle edge cases|your code here|to be implemented|FIXME' "$f" || true)"
  if [ -n "$bad" ]; then
    echo "FAIL plan: placeholder text in plan/sketch (not implementable):"; printf '   %s\n' "$bad"; fails=$((fails+1))
  fi
  # full tier must carry >=1 per-task Sketch
  if grep -qiE '^>.*tier:[[:space:]]*full' "$f"; then
    grep -qE '\*\*T-[0-9]+ sketch:\*\*' "$f" \
      || { echo "FAIL plan: full tier but no per-task **T-xxx sketch:** block"; fails=$((fails+1)); }
  fi
  [ "$fails" -eq 0 ] && echo "ok plan: §3 Implementation Flow present, no placeholders, tier-appropriate sketches"
  [ "$fails" -eq 0 ]
}

# ── R3: brainstorm deliberation persisted + linked from spec.
check_brainstorm_persisted() {
  local bf="$1" spec="$2" fails=0
  [ -f "$bf" ] || { echo "FAIL brainstorm: $bf not written — deliberation lost"; return 1; }
  local nopt; nopt="$(grep -oiE 'option|approach' "$bf" 2>/dev/null | grep -c . || true)"
  [ "${nopt:-0}" -ge 2 ] || { echo "FAIL brainstorm: <2 options/approaches recorded"; fails=$((fails+1)); }
  grep -qiE 'premortem' "$bf" || { echo "FAIL brainstorm: no premortem"; fails=$((fails+1)); }
  grep -qiE 'recommend' "$bf" || { echo "FAIL brainstorm: no recommendation"; fails=$((fails+1)); }
  if [ -n "${spec:-}" ]; then
    [ -f "$spec" ] && grep -qE '^>[[:space:]]*brainstorm:' "$spec" \
      || { echo "FAIL brainstorm: spec missing '> brainstorm:' link to the deliberation"; fails=$((fails+1)); }
  fi
  [ "$fails" -eq 0 ] && echo "ok brainstorm: persisted with >=2 options + premortem + recommendation, linked from spec"
  [ "$fails" -eq 0 ]
}

# ── R6: review must surface Standards-axis defects (FQN + cross-file duplication) WITH file:line, not just
# spec-axis. Used by the live review-standards-axis fixture on the produced review.md.
check_review_standards_axis() {
  local f="$1" fails=0
  [ -f "$f" ] || { echo "FAIL review: file not found: $f"; return 1; }
  # FQN-in-declaration finding with a file:line citation
  grep -iE 'fully.?qualif|FQN' "$f" | grep -qE '\.java:[0-9]+|:[0-9]+' \
    || { echo "FAIL review: no FQN-in-declaration finding with file:line (Standards axis)"; fails=$((fails+1)); }
  # cross-file duplication finding with a file:line citation
  grep -iE 'duplicat' "$f" | grep -qE '\.java:[0-9]+|:[0-9]+' \
    || { echo "FAIL review: no cross-file duplication finding with file:line (Standards axis)"; fails=$((fails+1)); }
  [ "$fails" -eq 0 ] && echo "ok review: Standards-axis FQN + duplication findings present with file:line"
  [ "$fails" -eq 0 ]
}
