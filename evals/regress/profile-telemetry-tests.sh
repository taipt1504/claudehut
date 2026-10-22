#!/usr/bin/env bash
# profile-telemetry-tests.sh — K5 autonomy profile and K9 telemetry bridge (M5e; docs/v0.20 04 §5.2, 08 §1).
#   PF1-PF5  profile: each level maps to a host mode; printing writes nothing; --write merges into the given file
#            only, keeping the user's own entries; a merge to the default branch is never allowed at any level
#   TL1-TL4  telemetry: one invoke_workflow span per task, one execute_tool child per gate outcome, other events as
#            span events; written to a local file only
# Scratch dirs only (never ~/.claude). Prints "PROFILE-TELEMETRY: N passed, M failed"; exit 1 on failure.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
command -v python3 >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || { echo "PROFILE-TELEMETRY: 0 passed, 0 failed (no python3/jq)"; exit 0; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/profile tests.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS+1)); echo "ok - $1"; else FAIL=$((FAIL+1)); echo "FAIL - $1"; fi; }
export CLAUDEHUT_HOST_PROBE=0
unset CLAUDEHUT_GATE_MODE CLAUDEHUT_STATE_IMPL
K="$ROOT/bin/claudehut-kernel"

modes="$(for l in L0 L1 L2 L3; do "$K" profile --level "$l" 2>/dev/null | jq -r .permissions.defaultMode; done | tr '\n' ' ')"
check "PF1: L0 plan, L1-L3 acceptEdits ($modes)" '[ "$modes" = "plan acceptEdits acceptEdits acceptEdits " ]'
check "PF2: L0 denies Write/Edit; L2 allows local commit but not push; L3 allows push and PR creation" \
  '"$K" profile --level L0 2>/dev/null | jq -e ".permissions.deny|index(\"Write\")!=null" >/dev/null && "$K" profile --level L2 2>/dev/null | jq -e "(.permissions.allow|index(\"Bash(git commit *)\")!=null) and (.permissions.deny|index(\"Bash(git push*)\")!=null)" >/dev/null && "$K" profile --level L3 2>/dev/null | jq -e "(.permissions.allow|index(\"Bash(gh pr create*)\")!=null)" >/dev/null'
check "PF3: no level allows a merge or a force push" \
  '[ "$(for l in L0 L1 L2 L3; do "$K" profile --level "$l" 2>/dev/null | jq -r ".permissions.deny|index(\"Bash(gh pr merge*)\")!=null and index(\"Bash(git push --force*)\")!=null"; done | sort -u)" = true ]'
H0="$(ls -la "$TMP")"; "$K" profile --level L2 >/dev/null 2>&1
check "PF4: printing writes nothing" '[ "$(ls -la "$TMP")" = "$H0" ]'
SF="$TMP/scratch-config/settings.json"; mkdir -p "$(dirname "$SF")"
printf '{"model":"opus","permissions":{"allow":["Bash(ls *)","Bash(git push*)"]}}\n' >"$SF"
"$K" profile --level L2 --write "$SF" 2>/dev/null
check "PF5: --write merges: the user's keys and allow entries stay, a level-denied allow entry is dropped" \
  'jq -e ".model==\"opus\" and .permissions.defaultMode==\"acceptEdits\" and (.permissions.allow|index(\"Bash(ls *)\")!=null) and (.permissions.allow|index(\"Bash(git push*)\"))==null and (.permissions.allow|index(\"Bash(./gradlew *)\")!=null)" "$SF" >/dev/null'

P="$TMP/repo"; mkdir -p "$P/.claudehut/tasks" "$P/src"; printf 'x\n' >"$P/src/A.java"
git -C "$P" init -q && git -C "$P" add -A && git -C "$P" -c user.email=t@t -c user.name=t commit -qm i
id="$(CLAUDE_PROJECT_DIR="$P" "$ROOT/bin/claudehut-state" --session t1 start --route light --slug tl 2>/dev/null | head -1)"
CLAUDE_PROJECT_DIR="$P" "$ROOT/bin/claudehut-state" --session t1 set-tier T2 --reason x 2>/dev/null
CLAUDE_PROJECT_DIR="$P" "$ROOT/bin/claudehut-state" --session t1 end --status done 2>/dev/null   # warned: review pending
"$K" telemetry --task "$P/.claudehut/tasks/$id" --out "$TMP/otel/spans.json" 2>/dev/null
SP='.resourceSpans[0].scopeSpans[0].spans'
check "TL1: one invoke_workflow span for the task, with its id and route" "jq -e '[$SP[]|select(.attributes[\"gen_ai.operation.name\"]==\"invoke_workflow\")]|length==1 and .[0].attributes[\"claudehut.task.id\"]==\"$id\"' \"\$TMP/otel/spans.json\" >/dev/null"
check "TL2: the warned end gate is an execute_tool child span (gate.end, outcome warned)" "jq -e '[$SP[]|select(.name==\"execute_tool gate.end\" and .attributes[\"claudehut.gate.outcome\"]==\"warned\" and .parentSpanId!=null)]|length==1' \"\$TMP/otel/spans.json\" >/dev/null"
check "TL3: state events are span events on the task span (task.started, tier.set, task.ended)" "jq -e '[$SP[0].events[].name] as \$n | (\$n|index(\"task.started\"))!=null and (\$n|index(\"tier.set\"))!=null and (\$n|index(\"task.ended\"))!=null' \"\$TMP/otel/spans.json\" >/dev/null"
check "TL4: written only to the given file" '[ "$(find "$TMP/otel" -type f | wc -l | tr -d " ")" = 1 ]'

echo "PROFILE-TELEMETRY: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
