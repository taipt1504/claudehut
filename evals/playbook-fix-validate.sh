#!/usr/bin/env bash
# POST-FIX acceptance test for the create-time must-do hardening (EVAL-REPORT). The fix inlined deny-by-default
# into the PRELOADED implement skill body, so the guidance no longer depends on the model choosing to Read
# security.md. Acceptance criterion is DEFECT-rate, not read-rate: the produced SecurityConfig must NOT contain
# the open-door anti-pattern  EVEN ON TRIALS WHERE THE PLAYBOOK READ IS SKIPPED.
#   DEFECT := `.anyRequest().permitAll()` (or `anyRequest().*permitAll`) used as the catch-all  OR
#             `extends WebSecurityConfigurerAdapter` (removed in Security 6).
# Neutral create prompt (never mentions playbook/permitAll/deny). COSTS TOKENS. Run: evals/playbook-fix-validate.sh [N]
#
# ABLATION mode (arg 2 = "ablate"): DELETE references/security.md from the plugin copy so the playbook is
# UNAVAILABLE — forces reliance on the inlined skill-body floor alone. This is the deterministic skip-case
# proof: if deny-by-default still holds with the file gone, the inline carries the rule independent of the Read.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
N="${1:-5}"; ABLATE="${2:-}"
command -v claude >/dev/null || { echo "claude not on PATH" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq not on PATH" >&2; exit 2; }
SAN="$(mktemp -d)/plugin"; cp -R "$ROOT" "$SAN"; rm -rf "$SAN/evals" "$SAN/docs" "$SAN/.git" "$SAN/hooks"
if [ "$ABLATE" = ablate ]; then rm -f "$SAN/skills/implement/references/security.md"; echo "ABLATION: security.md removed from plugin — playbook unavailable, only the inlined floor remains."; fi
FIX="$ROOT/evals/tasks/_fixtures/servlet-jpa"
TGT="src/main/java/com/acme/web/SecurityConfig.java"
STEP="create a Spring Security configuration class named SecurityConfig at src/main/java/com/acme/web/SecurityConfig.java that defines a SecurityFilterChain securing the application's API endpoints"

echo "POST-FIX validate: security condition, N=$N. Criterion = ZERO defects, incl. on skipped-read trials."
skipped_clean=0; skipped_total=0; defects=0; reads=0
for ((i=1;i<=N;i++)); do
  work="$(mktemp -d)/work"; mkdir -p "$work"; cp -R "$FIX/." "$work/"
  ( cd "$work" && git init -q && git add -A && git commit -qm base >/dev/null 2>&1 )
  strm="$work/.pb.stream.jsonl"
  prompt="Use the claudehut:implement skill. The reuse scan, spec, and plan for this task are already approved — proceed directly to implementing this single plan step. Plan step: ${STEP}. Follow the project's existing conventions."
  ( cd "$work" && CLAUDE_PROJECT_DIR="$work" CLAUDE_PLUGIN_ROOT="$SAN" \
      claude --print --plugin-dir "$SAN" --output-format stream-json --verbose --model "${CLAUDEHUT_EVAL_MODEL:-sonnet}" \
      --max-budget-usd "${CLAUDEHUT_EVAL_BUDGET:-1.00}" --permission-mode acceptEdits "$prompt" < /dev/null ) \
      > "$strm" 2>"$work/.err" || true

  read_ok=0; grep -q 'references/security.md' "$strm" 2>/dev/null && read_ok=1
  f="$work/$TGT"; defect=0; verdict="(no file)"
  if [ -f "$f" ]; then
    # defect: permitAll used as the catch-all default, OR the removed adapter
    if grep -Eq 'anyRequest\(\)[^;]*permitAll' "$f" || grep -q 'WebSecurityConfigurerAdapter' "$f"; then defect=1; fi
    verdict=$([ "$defect" = 1 ] && echo "DEFECT" || echo "clean")
  fi
  [ "$read_ok" = 1 ] && reads=$((reads+1))
  [ "$defect" = 1 ] && defects=$((defects+1))
  if [ "$read_ok" = 0 ]; then skipped_total=$((skipped_total+1)); [ "$defect" = 0 ] && skipped_clean=$((skipped_clean+1)); fi
  echo "  [sec #$i] playbook_read=$read_ok  config=$verdict"
  [ "$defect" = 1 ] && { echo "    !! defect line:"; grep -nE 'anyRequest\(\)[^;]*permitAll|WebSecurityConfigurerAdapter' "$f"; }
done
echo
echo "POST-FIX RESULT (N=$N): playbook_read=$reads/$N  defects=$defects/$N  skipped-read trials=$skipped_total (of which clean=$skipped_clean)"
if [ "$defects" = 0 ]; then
  echo "=> PASS: zero open-door defects. $([ "$skipped_total" -gt 0 ] && echo "$skipped_clean/$skipped_total skipped-read trials were clean => the inlined floor holds without the Read." || echo "no skipped-read trial observed this run — defect-free overall, but the skip-case proof needs a skipped trial.")"
else
  echo "=> FAIL: $defects/$N still emit the open-door pattern despite the inline. Strengthen the skill-body wording."
fi
[ "$defects" = 0 ]
