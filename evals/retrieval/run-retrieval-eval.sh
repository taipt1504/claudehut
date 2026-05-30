#!/usr/bin/env bash
# run-retrieval-eval.sh — seeded-learnings Phase-4 retrieval eval (DETERMINISTIC,
# no model calls, runs free). Proves the JIT ranker DISCRIMINATES BY RELEVANCE,
# not recency, against a seeded corpus whose relevant entries are deliberately the
# OLDEST (so the old head-N-recency behavior would miss them).
#
# Ground truth ("relevant") is SEMANTIC (domain/intent), authored independently of
# the scoring formula — see scenarios.json `why`. Two anti-circular discriminators:
#   - a relevant entry with NO shared tag, caught only by package overlap (S_path);
#   - a distractor with a coincidentally-shared tag, floored out.
#
# HONEST SCOPE: a self-authored corpus proves the MECHANISM discriminates by
# relevance signal (CI-lockable). It does NOT prove "Phase 4 improves real runs" —
# that needs the opt-in $ A/B and depends on real corpora having relevant-but-old
# structure. Do not read more into a green result than that.
set -uo pipefail

EVAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
PLUGIN_ROOT="$(cd "$EVAL_DIR/../.." && pwd -P)"
RETR="$PLUGIN_ROOT/skills/learn/scripts/retrieve-relevant.sh"
CORPUS="$EVAL_DIR/corpus.jsonl"
SCEN="$EVAL_DIR/scenarios.json"
K=5
command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 2; }

PASS=0; FAIL=0; declare -a FL=()
ok() { printf "  \033[32m✓\033[0m %s\n" "$1"; PASS=$((PASS+1)); }
no() { printf "  \033[31m✗\033[0m %s :: %s\n" "$1" "$2"; FAIL=$((FAIL+1)); FL+=("$1: $2"); }

# ids retrieved by the relevance ranker, as a JSON array (task_ids ride in backticks)
ranker_ids() { grep -oE '`[A-Z][0-9]+`' | tr -d '`' | jq -R . | jq -s 'unique'; }
# the OLD behavior: top-K by recency (what regenerate-recent.sh did)
recency_ids() { jq -s --argjson k "$K" 'sort_by(.ts) | reverse | .[0:$k] | [.[].task_id]' "$CORPUS"; }

printf '%-10s | %-22s | %-22s | %s\n' "scenario" "relevance (precision/recall)" "recency (precision)" "count"
printf -- '-%.0s' {1..78}; echo

n_scen="$(jq 'length' "$SCEN")"
for i in $(seq 0 $((n_scen - 1))); do
  s="$(jq -c ".[$i]" "$SCEN")"
  name="$(printf '%s' "$s" | jq -r '.name')"
  intent="$(printf '%s' "$s" | jq -r '.intent')"
  rel="$(printf '%s' "$s" | jq -c '.relevant')"
  din="$(printf '%s' "$s" | jq -r '.discriminator_in')"
  dout="$(printf '%s' "$s" | jq -c '.discriminator_out')"

  d="$(mktemp -d)"; mkdir -p "$d/.claudehut/memory" "$d/.claudehut/plans"
  cp "$CORPUS" "$d/.claudehut/memory/learnings.jsonl"
  printf '%s' "$s" | jq -r '.stack[] | "- web_or_other: \(.)"' >/dev/null 2>&1 || true
  # stack-signals.md: one "- k: v" line per stack value (key name is cosmetic; the
  # ranker folds all non-"none" values into the tag query regardless of key).
  : > "$d/.claudehut/memory/stack-signals.md"
  printf '%s' "$s" | jq -r '.stack[]' | while read -r v; do printf -- '- sig_%s: %s\n' "$v" "$v" >> "$d/.claudehut/memory/stack-signals.md"; done
  # plan file(s)
  printf '# Plan\n## Task 1\n' > "$d/.claudehut/plans/t-eval-plan.md"
  printf '%s' "$s" | jq -r '.plan_files[]' | while read -r f; do printf -- '- create: `%s`\n' "$f" >> "$d/.claudehut/plans/t-eval-plan.md"; done

  ret="$(bash "$RETR" "$d" "$intent" t-eval "$K" | ranker_ids)"
  rec="$(recency_ids)"
  rm -rf "$d"

  m="$(jq -n --argjson ret "$ret" --argjson rel "$rel" --argjson rec "$rec" '
    ($ret - ($ret - $rel)) as $hit
    | ($rec - ($rec - $rel)) as $rhit
    | { count: ($ret|length),
        extra: ($ret - $rel),
        missing: ($rel - $ret),
        precision: (if ($ret|length)==0 then 0 else (($hit|length)*100/($ret|length)|floor) end),
        recall: (if ($rel|length)==0 then 100 else (($hit|length)*100/($rel|length)|floor) end),
        rec_precision: (if ($rec|length)==0 then 0 else (($rhit|length)*100/($rec|length)|floor) end) }')"
  cnt="$(printf '%s' "$m" | jq -r '.count')"
  prec="$(printf '%s' "$m" | jq -r '.precision')"
  rec_prec="$(printf '%s' "$m" | jq -r '.rec_precision')"
  recall="$(printf '%s' "$m" | jq -r '.recall')"
  nrel="$(printf '%s' "$rel" | jq 'length')"
  printf '%-10s | rel %3d%% / rec %3d%%        | %3d%%                   | %d (rel=%d)\n' "$name" "$prec" "$recall" "$rec_prec" "$cnt" "$nrel"

  # Assertions ---------------------------------------------------------------
  [[ "$(printf '%s' "$m" | jq -r '.extra|length')" == "0" ]] && ok "$name: precision 100% (no irrelevant entry retrieved)" || no "$name precision" "extra=$(printf '%s' "$m"|jq -c .extra)"
  [[ "$(printf '%s' "$m" | jq -r '.missing|length')" == "0" ]] && ok "$name: recall 100% (all relevant retrieved)" || no "$name recall" "missing=$(printf '%s' "$m"|jq -c .missing)"
  [[ "$cnt" == "$nrel" ]] && ok "$name: returns $cnt (== relevant), no padding to K=$K" || no "$name no-pad" "count=$cnt rel=$nrel"
  [[ "$prec" -gt "$rec_prec" ]] && ok "$name: relevance beats recency ($prec% > $rec_prec%)" || no "$name rel>rec" "rel=$prec rec=$rec_prec"
  # anti-circular discriminator: the no-shared-tag, same-package entry IS retrieved
  [[ "$(printf '%s' "$ret" | jq --arg x "$din" 'index($x)!=null')" == "true" ]] && ok "$name: discriminator '$din' retrieved (relevance via package, not tag-equality)" || no "$name disc-in" "$din not retrieved"
  # shared-tag distractors + tombstone are NOT retrieved
  while read -r x; do
    [[ -z "$x" ]] && continue
    [[ "$(printf '%s' "$ret" | jq --arg x "$x" 'index($x)!=null')" == "false" ]] && ok "$name: distractor '$x' excluded (shared tag/pkg but off-domain or tombstoned)" || no "$name disc-out" "$x wrongly retrieved"
  done < <(printf '%s' "$dout" | jq -r '.[]')
done

echo ""
echo "retrieval-eval: Pass=$PASS Fail=$FAIL"
[[ "$FAIL" -gt 0 ]] && { printf '  - %s\n' "${FL[@]}"; exit 1; } || exit 0
