#!/usr/bin/env bash
# propose-rules.sh [K] — Phase 4.5 meta-learning.
#
# Scan learnings.jsonl for an anti-pattern that RECURS (same signature >= K times)
# and, if not already proposed, write a PROPOSAL to .claudehut/proposals/ suggesting
# it be hardened into the enforcement layer (a rule/skill). HUMAN APPROVAL REQUIRED —
# this NEVER auto-edits rules/ or skills/. It only surfaces "we keep seeing X".
#
# Dedup keys off the learner-written `signature` field (sha256) — the SAME stable
# key the rest of the memory subsystem uses — never a freshly re-derived hash
# (key drift is how these subsystems silently die; see learnings-key.sh). Falls
# back to lower(title):category only when an entry predates signatures.
set -uo pipefail

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
K="${1:-3}"
case "$K" in ''|*[!0-9]*) K=3 ;; esac
command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 2; }

LEARNINGS="$PROJECT_ROOT/.claudehut/memory/learnings.jsonl"
[[ -s "$LEARNINGS" ]] || { echo "propose-rules: no learnings yet"; exit 0; }
PROP_DIR="$PROJECT_ROOT/.claudehut/proposals"
mkdir -p "$PROP_DIR"
# shellcheck source=learnings-key.sh
source "$(dirname "${BASH_SOURCE[0]:-$0}")/learnings-key.sh" 2>/dev/null || LEARNINGS_KEY_JQ_DEF='def learning_key: ((.title // "") | ascii_downcase) + ":" + (.category // "");'

# Recurring anti-patterns: group by (.signature // learning_key), keep groups >= K.
RECUR="$(jq -s -r "${LEARNINGS_KEY_JQ_DEF}
  [ .[] | select((.category // \"\") == \"anti-pattern\")
        | { key: (.signature // learning_key), title: (.title // \"\"),
            content: (.content // \"\"), tags: (.tags // []) } ]
  | group_by(.key) | map(select(length >= ${K}))
  | map({ key: .[0].key, title: .[0].title, content: .[0].content,
          tags: (.[0].tags), count: length })
  | .[] | @base64" "$LEARNINGS" 2>/dev/null || true)"

created=0
while IFS= read -r row; do
  [[ -z "$row" ]] && continue
  obj="$(printf '%s' "$row" | base64 --decode 2>/dev/null || echo '')"
  [[ -z "$obj" ]] && continue
  key="$(printf '%s' "$obj" | jq -r '.key')"
  # Idempotent: skip if any existing proposal already records this key.
  if grep -rqlF "proposal-key: $key" "$PROP_DIR" 2>/dev/null; then continue; fi
  title="$(printf '%s' "$obj" | jq -r '.title')"
  content="$(printf '%s' "$obj" | jq -r '.content')"
  count="$(printf '%s' "$obj" | jq -r '.count')"
  tags="$(printf '%s' "$obj" | jq -r '(.tags // []) | join(", ")')"
  slug="$(printf '%s' "$title" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9' '-' | sed 's/--*/-/g; s/^-//; s/-$//' | cut -c1-50)"
  [[ -z "$slug" ]] && slug="proposal"
  out="$PROP_DIR/${slug}.md"
  i=1; while [[ -e "$out" ]] && ! grep -qF "proposal-key: $key" "$out" 2>/dev/null; do out="$PROP_DIR/${slug}-${i}.md"; i=$((i + 1)); done
  cat > "$out" <<EOF
# Rule/skill proposal: $title

<!-- proposal-key: $key -->
- status: pending
- recurrence: $count occurrences (category: anti-pattern)
- tags: $tags

## The recurring anti-pattern

$content

## Proposed structural prevention — HUMAN APPROVAL REQUIRED

This anti-pattern has recurred **$count** times. Consider hardening it into the
enforcement layer (ClaudeHut will NOT auto-apply this):

- a \`.claude/rules/*.md\` rule (with \`paths:\` frontmatter) that flags it at read time, or
- a guard in the relevant skill / a PreToolUse check.

To act: create the rule/skill yourself, then set \`status: approved\`. To dismiss:
delete this file. Either way ClaudeHut never edits rules on its own.
EOF
  created=$((created + 1))
done <<EOF
$RECUR
EOF
echo "propose-rules: $created new proposal(s) for anti-patterns recurring >= $K times"
exit 0
