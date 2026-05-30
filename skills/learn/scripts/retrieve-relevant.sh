#!/usr/bin/env bash
# retrieve-relevant.sh PROJECT_ROOT USER_INTENT TASK_ID [K]
#
# Phase 4.1 — JIT relevance retrieval. Emits a "## Relevant learnings" markdown
# block of the top-K learnings relevant to THIS task, ranked by
#   score = 0.45*S_path + 0.30*S_tag + 0.10*S_title + 0.15*S_prior   (R>0.05 floor)
# where R = 0.45*S_path+0.30*S_tag+0.10*S_title is the relevance subtotal and the
# floor is applied to R (before the prior) so a cold entry at zero relevance never
# surfaces. Replaces the static head-200 "Recent learnings" dump in dispatch-prompt.sh.
#
# SELF-DEGRADING (this is load-bearing): the dispatch-prompt.sh callers run
# `set -euo pipefail`, so this script must NEVER exit non-zero and must NEVER emit
# PARTIAL output (a stub appended below half-streamed bullets = a Frankenstein
# section). The whole block is buffered into a variable and printed exactly ONCE;
# any failure prints only the stub. Hence: no `set -e` here, explicit fallbacks.
set -uo pipefail

PROJECT_ROOT="${1:-$PWD}"
USER_INTENT="${2:-}"
TASK_ID="${3:-}"
K="${4:-5}"

HEAD=$'\n## Relevant learnings\n'
STUB="${HEAD}"$'\n(none yet — finish a task to populate)'
_stub() { printf '%s\n' "$STUB"; exit 0; }

command -v jq >/dev/null 2>&1 || _stub
LEARNINGS="$PROJECT_ROOT/.claudehut/memory/learnings.jsonl"
[[ -s "$LEARNINGS" ]] || _stub

KEY_LIB="$(dirname "${BASH_SOURCE[0]:-$0}")/learnings-key.sh"
# shellcheck source=learnings-key.sh
source "$KEY_LIB" 2>/dev/null || _stub

USEFULNESS="$PROJECT_ROOT/.claudehut/memory/usefulness.json"
[[ -s "$USEFULNESS" ]] || USEFULNESS=""

STOP="a an the in of to for and or with add create update implement using via from on by at fix"

# --- Query construction (bash 3.2 safe: POSIX awk split() for paths; lowercase via tr) ---
# plan_pkgs: package dirs from the plan's "- create|modify|test: `path`" lines.
PLAN_FILE="$PROJECT_ROOT/.claudehut/plans/${TASK_ID}-plan.md"
plan_pkgs_list=""
if [[ -f "$PLAN_FILE" ]]; then
  plan_pkgs_list="$(awk '
    /^[[:space:]]*-[[:space:]]*(create|modify|test):/ {
      n = split($0, a, "`"); if (n >= 2) { p = a[2];
        sub(/\/[^\/]+$/, "", p);            # dirname
        if (p != "") print tolower(p); }
    }' "$PLAN_FILE" 2>/dev/null | sort -u || true)"
fi

# stack_tags: every non-"none" value in stack-signals.md.
STACK_FILE="$PROJECT_ROOT/.claudehut/memory/stack-signals.md"
stack_tags_list=""
if [[ -f "$STACK_FILE" ]]; then
  stack_tags_list="$(awk '
    /^- [a-z_]+:/ { sub(/^- [a-z_]+:[[:space:]]*/, ""); sub(/[[:space:]]*#.*/, "");
      if ($0 != "none" && $0 != "") print tolower($0); }' "$STACK_FILE" 2>/dev/null | sort -u || true)"
fi

# intent tokens: lowercase alphanumeric words of USER_INTENT, stopword-filtered.
intent_tokens_list="$(printf '%s' "$USER_INTENT" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9' '\n' \
  | awk -v stop=" $STOP " 'length($0)>1 && index(stop, " "$0" ")==0 {print}' | sort -u || true)"

# basenames (no extension) of plan paths → title-query terms.
base_terms_list=""
if [[ -f "$PLAN_FILE" ]]; then
  base_terms_list="$(awk '
    /^[[:space:]]*-[[:space:]]*(create|modify|test):/ {
      n = split($0, a, "`"); if (n >= 2) { p = a[2];
        sub(/.*\//, "", p); sub(/\.[^.]+$/, "", p);   # basename, strip ext
        if (p != "") print tolower(p); }
    }' "$PLAN_FILE" 2>/dev/null | sort -u || true)"
fi

# Turn a newline list into a compact JSON array (empty list -> []).
_to_json_array() { printf '%s\n' "$1" | jq -R . 2>/dev/null | jq -s 'map(select(length>0))' 2>/dev/null || echo '[]'; }
plan_pkgs_json="$(_to_json_array "$plan_pkgs_list")"
q_tags_json="$(printf '%s\n%s\n' "$intent_tokens_list" "$stack_tags_list" | jq -R . 2>/dev/null | jq -s 'map(select(length>0))|unique' 2>/dev/null || echo '[]')"
q_title_json="$(printf '%s\n%s\n' "$intent_tokens_list" "$base_terms_list" | jq -R . 2>/dev/null | jq -s 'map(select(length>0))|unique' 2>/dev/null || echo '[]')"
stop_json="$(printf '%s\n' $STOP | jq -R . | jq -s '.' 2>/dev/null || echo '[]')"

# --- Scoring (single jq pass; reads learnings.jsonl via -s, usefulness via --argjson) ---
USE_JSON='{}'
[[ -n "$USEFULNESS" ]] && USE_JSON="$(jq -c '.' "$USEFULNESS" 2>/dev/null || echo '{}')"

JQ_PROG="${LEARNINGS_KEY_JQ_DEF}
def norm(\$xs): (\$xs // []) | map(ascii_downcase) | unique;
def inter(\$a;\$b): \$a | map(select(. as \$x | \$b | index(\$x)));
def jaccard(\$a;\$b): (inter(\$a;\$b)|length) as \$i | ((\$a+\$b)|unique|length) as \$u | (if \$u==0 then 0 else \$i/\$u end);
def recall(\$a;\$b): (inter(\$a;\$b)|length) as \$i | (\$a|length) as \$d | (if \$d==0 then 0 else \$i/\$d end);
def terms(\$t): (\$t // \"\") | ascii_downcase | [scan(\"[a-z0-9]+\")] | map(select((. as \$w | \$stop | index(\$w)) | not)) | map(select(length>1)) | unique;

# 4.2: dedup the merged candidate pool by learning_key. learnings.jsonl entries
# come FIRST in the stream, so //= keeps the learner-authored copy over an MCP
# mirror of the same key (MCP-only entities survive and become retrievable).
(reduce .[] as \$e ({}; .[(\$e | learning_key)] //= \$e) | [ .[] ]) as \$cands
| [ \$cands[]
  | select((.category // \"\") != \"tombstone\" and (.deprecated != true))
  | ((.files_touched // []) | map(ascii_downcase) | map(sub(\"/[^/]+\$\";\"\")) | unique) as \$epkg
  | (norm(.tags)) as \$etags
  | (terms(.title)) as \$ettl
  | (if (\$plan_pkgs|length)==0 then 0 else (inter(\$epkg;\$plan_pkgs)|length) / (\$plan_pkgs|length) end) as \$S_path
  | jaccard(\$etags; \$q_tags) as \$S_tag
  | recall(\$ettl; \$q_title) as \$S_title
  | (0.45*\$S_path + 0.30*\$S_tag + 0.10*\$S_title) as \$R
  | select(\$R > 0.05)
  | (. | learning_key) as \$sig
  | ((\$use[\$sig].useful // 0)) as \$uf | ((\$use[\$sig].used // 0)) as \$ud
  | ((\$uf + 1) / (\$ud + 2)) as \$S_prior
  | (\$R + 0.15*\$S_prior) as \$score
  | { category: (.category // \"\"), title: (.title // \"\"), task_id: (.task_id // \"\"),
      tags: (.tags // []), sig: \$sig, score: \$score, sprior: \$S_prior,
      tsx: ((.ts // \"\") | (try fromdateiso8601 catch 0)) }
]
| sort_by([ -.score, -.sprior, -.tsx, .task_id, .title ])
| .[0:\$K]
| .[] | [.category, .title, .task_id, (.tags|join(\",\")), .sig] | @tsv"

# 4.2: ingest the memory MCP store (mcp-graph.json) as ADDITIONAL candidates,
# model-free — we read the server's own JSON store via jq, no live-model call in
# this bash hot path. Entities are learnings the learner mirrored via the MCP
# tools; tags/files/ts/content ride in observations as "tag:"/"file:"/"ts:"/
# "content:" prefixes. Absent/malformed graph contributes nothing (degrades clean).
MCP_GRAPH="$PROJECT_ROOT/.claudehut/memory/mcp-graph.json"
MCP_MAPPED=""
if [[ -s "$MCP_GRAPH" ]]; then
  MCP_MAPPED="$(jq -c 'select(.type=="entity") | {
      category: (.entityType // "pattern"),
      title: (.name // ""),
      content: ([.observations[]? | select(startswith("content:")) | sub("^content:";"")] | (.[0] // "")),
      tags: [.observations[]? | select(startswith("tag:")) | sub("^tag:";"")],
      files_touched: [.observations[]? | select(startswith("file:")) | sub("^file:";"")],
      ts: ([.observations[]? | select(startswith("ts:")) | sub("^ts:";"")] | (.[0] // "")),
      task_id: "mcp" }' "$MCP_GRAPH" 2>/dev/null || true)"
fi
# learnings.jsonl FIRST so it wins dedup over an MCP mirror of the same key.
CANDIDATES="$(printf '%s\n%s\n' "$(cat "$LEARNINGS" 2>/dev/null || true)" "$MCP_MAPPED")"

SEL="$(printf '%s\n' "$CANDIDATES" | jq -s -r \
  --argjson plan_pkgs "$plan_pkgs_json" \
  --argjson q_tags "$q_tags_json" \
  --argjson q_title "$q_title_json" \
  --argjson stop "$stop_json" \
  --argjson use "$USE_JSON" \
  --argjson K "$K" \
  "$JQ_PROG" 2>/dev/null || true)"

[[ -n "$SEL" ]] || _stub

# --- Format (buffered) + collect sigs ---
BULLETS=""
SIGS_JSON="[]"
while IFS=$'\t' read -r cat title tid tags sig; do
  [[ -z "$title" ]] && continue
  if [[ -n "$tags" ]]; then
    BULLETS="${BULLETS}- **${cat}** — ${title} \`${tid}\` _[${tags}]_"$'\n'
  else
    BULLETS="${BULLETS}- **${cat}** — ${title} \`${tid}\`"$'\n'
  fi
  SIGS_JSON="$(printf '%s' "$SIGS_JSON" | jq -c --arg s "$sig" '. + [$s]' 2>/dev/null || echo "$SIGS_JSON")"
done <<EOF
$SEL
EOF

[[ -n "$BULLETS" ]] || _stub

# Single emit (no partial output possible — everything was buffered above).
printf '%s\n%s' "$HEAD" "$BULLETS"

# --- Retrieval log: APPEND one line (never overwrite — all 6 phases write the same
# file for this task; update-usefulness unions+dedups sigs at read time, so credit
# is attributed correctly across phases). Best-effort; failure must not abort. ---
STATE_DIR="$PROJECT_ROOT/.claudehut/state"
if [[ "$SIGS_JSON" != "[]" ]] && mkdir -p "$STATE_DIR" 2>/dev/null; then
  TS="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '')"
  LINE="$(jq -cn --arg t "$TASK_ID" --arg ts "$TS" --argjson sigs "$SIGS_JSON" \
    '{task_id:$t, ts:$ts, sigs:$sigs}' 2>/dev/null || true)"
  [[ -n "$LINE" ]] && printf '%s\n' "$LINE" >> "$STATE_DIR/retrieval-${TASK_ID}.json" 2>/dev/null || true
fi
exit 0
