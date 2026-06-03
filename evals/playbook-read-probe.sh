#!/usr/bin/env bash
# Live measurement: at CREATE time, does the agent OPEN the matching deep playbook (skills/implement/
# references/<X>.md)? This is EVAL-REPORT residual #7-followup — the soft model Read the report flagged
# as unmeasured. The preloaded `implement` skill body (component->playbook table + "READ it when CREATING")
# is the reliable part; THIS probe measures the soft part: does that instruction actually drive a Read?
#
# Method (mirrors p7-init.sh capture): sanitized plugin (evals/docs/.git stripped) WITH hooks/ ALSO removed
# so the write-gate can't thrash on denied writes — the playbook Read (per the skill) happens BEFORE the
# write, so we don't need the write to succeed. Skill named explicitly == the subagent's preloaded-always-on
# condition. Prompt is NEUTRAL about playbooks/references (the SKILL body must be what drives the read, not us).
# Per trial we record, from the top-level stream-json:
#   skill_active     - implement skill loaded (DENOMINATOR GATE; trials without it don't count toward read rate)
#   ref_read_ok      - a SUCCESSFUL Read of skills/implement/references/<expected>.md (suffix match)
#   ref_read_err     - a Read of that playbook that ERRORED (path-resolution failure: tried-but-failed != declined)
#   any_ref_ok       - successful Read of ANY references/*.md (looser)
#   read_before_write- the matching-playbook Read index < first Edit/Write of the target file
# COSTS TOKENS. Run ONE trial first and inspect the raw transcript before scaling:  evals/playbook-read-probe.sh 1
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
N="${1:-3}"
FIXTURE="$ROOT/evals/tasks/_fixtures/servlet-jpa"
RESULTS="$ROOT/evals/results"; mkdir -p "$RESULTS"
command -v claude >/dev/null || { echo "claude not on PATH" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq not on PATH" >&2; exit 2; }
num() { case "$1" in ''|*[!0-9.]*) echo 0 ;; *) echo "$1" ;; esac; }

# sanitized plugin: strip held-out (evals/docs/.git) AND hooks/ (no gate thrash for a read-only measurement)
SAN="$(mktemp -d)/plugin"; cp -R "$ROOT" "$SAN"; rm -rf "$SAN/evals" "$SAN/docs" "$SAN/.git" "$SAN/hooks"

# Conditions: (component label | expected playbook suffix | target file | neutral create prompt)
COND_LABEL=(controller     entity)
COND_REF=(web.md           jpa.md)
COND_FILE=("src/main/java/com/acme/web/UserController.java" "src/main/java/com/acme/web/OrderEntity.java")
COND_PROMPT=(
"create a Spring MVC REST controller named UserController at src/main/java/com/acme/web/UserController.java exposing GET /api/users/{id} that returns a user response"
"create a JPA entity named OrderEntity at src/main/java/com/acme/web/OrderEntity.java with a Long id and a BigDecimal amount field"
)

echo "playbook-read probe: N=$N per condition, sanitized plugin (hooks stripped). Neutral create prompts."
for c in 0 1; do
  lbl="${COND_LABEL[$c]}"; ref="${COND_REF[$c]}"; tgt="${COND_FILE[$c]}"; step="${COND_PROMPT[$c]}"
  sa=0; rok=0; rerr=0; aok=0; rbw=0
  for ((i=1;i<=N;i++)); do
    work="$(mktemp -d)/work"; mkdir -p "$work"; cp -R "$FIXTURE/." "$work/"
    ( cd "$work" && git init -q && git add -A && git commit -qm base >/dev/null 2>&1 )
    strm="$work/.pb.stream.jsonl"
    prompt="Use the claudehut:implement skill. The reuse scan, spec, and plan for this task are already approved — proceed directly to implementing this single plan step. Plan step: ${step}. Follow the project's existing conventions."
    ( cd "$work" && CLAUDE_PROJECT_DIR="$work" CLAUDE_PLUGIN_ROOT="$SAN" \
        claude --print --plugin-dir "$SAN" --output-format stream-json --verbose --model "${CLAUDEHUT_EVAL_MODEL:-sonnet}" \
        --max-budget-usd "${CLAUDEHUT_EVAL_BUDGET:-1.00}" --permission-mode acceptEdits "$prompt" < /dev/null ) \
        > "$strm" 2>"$work/.err" || true

    # --- detectors over the top-level stream-json (suffix-matched paths; declined vs errored distinguished) ---
    # skill_active: a Skill tool_use selecting "implement"
    skill_active=$(jq -rc 'select(.type=="assistant")|.message.content[]?|select(.type=="tool_use" and .name=="Skill")|.input.command // .input.skill // ""' "$strm" 2>/dev/null | grep -ci 'implement' || true)
    # Read tool_uses: emit "<tool_use_id>\t<file_path>" for any Read whose path ends in references/*.md
    refreads=$(jq -rc 'select(.type=="assistant")|.message.content[]?|select(.type=="tool_use" and .name=="Read")|[.id, (.input.file_path // "")]|@tsv' "$strm" 2>/dev/null || true)
    # tool_results that errored (is_error true): collect their tool_use_id
    errids=$(jq -rc 'select(.type=="user")|.message.content[]?|select(.type=="tool_result" and (.is_error==true))|.tool_use_id' "$strm" 2>/dev/null || true)

    ok=0; er=0; anyok=0
    while IFS=$'\t' read -r id path; do
      [ -n "$path" ] || continue
      case "$path" in
        */references/*.md)
          if printf '%s\n' "$errids" | grep -qx "$id"; then er=1; else anyok=1; fi
          case "$path" in
            */references/"$ref")
              if printf '%s\n' "$errids" | grep -qx "$id"; then er=1; else ok=1; fi ;;
          esac ;;
      esac
    done <<< "$refreads"

    # read_before_write: line index of first successful matching ref Read < first Edit/Write of target file
    ridx=$(grep -n "references/$ref" "$strm" 2>/dev/null | head -1 | cut -d: -f1); ridx="${ridx:-999999}"
    widx=$(grep -n "$(basename "$tgt")" "$strm" 2>/dev/null | grep -E '"name":"(Edit|Write)"' | head -1 | cut -d: -f1); widx="${widx:-0}"
    bw=0; [ "$ok" = 1 ] && [ "$ridx" -lt "${widx:-0}" ] 2>/dev/null && bw=1

    [ "$skill_active" -gt 0 ] 2>/dev/null && sa=$((sa+1))
    rok=$((rok+ok)); rerr=$((rerr+er)); aok=$((aok+anyok)); rbw=$((rbw+bw))
    echo "  [$lbl #$i] skill_active=$skill_active  ref_read_ok=$ok  ref_read_err=$er  any_ref_ok=$anyok  read_before_write=$bw"
    echo "      transcript: $strm"
  done
  echo "  == $lbl (expect references/$ref): skill_active=$sa/$N  ref_read_ok=$rok/$N  ref_read_err=$rerr/$N  any_ref_ok=$aok/$N  read_before_write=$rbw/$N"
done
echo
echo "Interpret: read_before_write is the headline. errored reads dominating => relative-path resolution bug (fix: skill hands \${CLAUDE_PLUGIN_ROOT}-resolvable paths), NOT a declined-read."
