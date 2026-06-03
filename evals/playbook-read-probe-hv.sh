#!/usr/bin/env bash
# Playbook-read probe, HIGH-VALUE domains — the ones where skipping the playbook is a REAL defect, not a
# style miss (the model is least likely to know Spring Security 6 / Kafka idempotency / Reactor specifics
# from training alone). Companion to playbook-read-probe.sh (which covered the easy web/jpa cases). Same
# validated detectors; per-condition fixture (security on servlet-jpa, reactive+messaging on reactive-kafka).
# COSTS TOKENS. Run: evals/playbook-read-probe-hv.sh [N]   (default N=3 per condition)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
N="${1:-3}"
RESULTS="$ROOT/evals/results"; mkdir -p "$RESULTS"
command -v claude >/dev/null || { echo "claude not on PATH" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq not on PATH" >&2; exit 2; }

SAN="$(mktemp -d)/plugin"; cp -R "$ROOT" "$SAN"; rm -rf "$SAN/evals" "$SAN/docs" "$SAN/.git" "$SAN/hooks"
SVLT="$ROOT/evals/tasks/_fixtures/servlet-jpa"; RKAF="$ROOT/evals/tasks/_fixtures/reactive-kafka"

# (label | expected playbook | fixture | target file | neutral create prompt)
COND_LABEL=(security messaging reactive)
COND_REF=(security.md messaging.md reactive.md)
COND_FIX=("$SVLT" "$RKAF" "$RKAF")
COND_FILE=("src/main/java/com/acme/web/SecurityConfig.java" "src/main/java/com/acme/app/OrderEventListener.java" "src/main/java/com/acme/app/UserHandler.java")
COND_PROMPT=(
"create a Spring Security configuration class named SecurityConfig at src/main/java/com/acme/web/SecurityConfig.java that defines a SecurityFilterChain securing the application's API endpoints"
"create a Kafka consumer named OrderEventListener at src/main/java/com/acme/app/OrderEventListener.java with a @KafkaListener method that handles incoming OrderEvent messages"
"create a Spring WebFlux handler named UserHandler at src/main/java/com/acme/app/UserHandler.java with a method returning Mono<ServerResponse> for GET /api/users/{id}"
)

echo "playbook-read HIGH-VALUE probe: N=$N per condition (security, messaging, reactive). Neutral create prompts."
for c in 0 1 2; do
  lbl="${COND_LABEL[$c]}"; ref="${COND_REF[$c]}"; fix="${COND_FIX[$c]}"; tgt="${COND_FILE[$c]}"; step="${COND_PROMPT[$c]}"
  sa=0; rok=0; rerr=0; aok=0; rbw=0
  for ((i=1;i<=N;i++)); do
    work="$(mktemp -d)/work"; mkdir -p "$work"; cp -R "$fix/." "$work/"
    ( cd "$work" && git init -q && git add -A && git commit -qm base >/dev/null 2>&1 )
    strm="$work/.pb.stream.jsonl"
    prompt="Use the claudehut:implement skill. The reuse scan, spec, and plan for this task are already approved — proceed directly to implementing this single plan step. Plan step: ${step}. Follow the project's existing conventions."
    ( cd "$work" && CLAUDE_PROJECT_DIR="$work" CLAUDE_PLUGIN_ROOT="$SAN" \
        claude --print --plugin-dir "$SAN" --output-format stream-json --verbose --model "${CLAUDEHUT_EVAL_MODEL:-sonnet}" \
        --max-budget-usd "${CLAUDEHUT_EVAL_BUDGET:-1.00}" --permission-mode acceptEdits "$prompt" < /dev/null ) \
        > "$strm" 2>"$work/.err" || true

    skill_active=$(jq -rc 'select(.type=="assistant")|.message.content[]?|select(.type=="tool_use" and .name=="Skill")|.input.command // .input.skill // ""' "$strm" 2>/dev/null | grep -ci 'implement' || true)
    refreads=$(jq -rc 'select(.type=="assistant")|.message.content[]?|select(.type=="tool_use" and .name=="Read")|[.id, (.input.file_path // "")]|@tsv' "$strm" 2>/dev/null || true)
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
echo "These are the domains where a skipped playbook = real defect. Compare read_before_write to web/jpa (5/6)."
