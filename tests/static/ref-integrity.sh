#!/usr/bin/env bash
# tests/static/ref-integrity.sh
#
# Bidirectional reference link integrity:
#   1. Skill cites references/X.md → X.md must exist (forward, already in run-all.sh)
#   2. Rule cites skill/rule path → target must exist (reverse)
#   3. Agent cites skill/rule path → target must exist (reverse)
#   4. rules-index.json entries → rule file must exist

set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$PLUGIN_ROOT"

PASS=0; FAIL=0
declare -a FAIL_LIST=()

pass() { printf "  \033[32m✓\033[0m %s\n" "$1"; PASS=$((PASS+1)); }
fail() { printf "  \033[31m✗\033[0m %s :: %s\n" "$1" "$2"; FAIL=$((FAIL+1)); FAIL_LIST+=("$1: $2"); }

echo "===== BIDIRECTIONAL REFERENCE INTEGRITY ====="
echo ""

# Skill citations of rules
echo "--- Skills citing rules ---"
broken=0
for skill in skills/*/SKILL.md skills/*/references/*.md; do
  [[ -f "$skill" ]] || continue
  for ref in $(grep -oE 'rules/[a-z-]+/[a-z0-9-]+\.md' "$skill" 2>/dev/null | sort -u); do
    if [[ ! -f "$ref" ]]; then
      echo "  broken in $skill: $ref"
      broken=$((broken + 1))
    fi
  done
done
[[ $broken -eq 0 ]] && pass "all skill→rule citations resolve" || fail "skill→rule" "$broken broken"

# Rule citations of skills
echo "--- Rules citing skills ---"
broken=0
for rule in rules/*/*.md; do
  for ref in $(grep -oE 'claudehut:[a-z0-9-]+' "$rule" 2>/dev/null | sort -u); do
    skill_name="${ref#claudehut:}"
    if [[ ! -d "skills/$skill_name" ]]; then
      echo "  broken in $rule: $ref (no skills/$skill_name/)"
      broken=$((broken + 1))
    fi
  done
done
[[ $broken -eq 0 ]] && pass "all rule→skill citations resolve" || fail "rule→skill" "$broken broken"

# Agent citations of skills
echo "--- Agents citing skills ---"
broken=0
for agent in agents/*.md; do
  for ref in $(grep -oE '/claudehut:[a-z0-9-]+' "$agent" 2>/dev/null | sort -u); do
    skill_name="${ref#/claudehut:}"
    if [[ ! -d "skills/$skill_name" ]]; then
      echo "  broken in $agent: $ref"
      broken=$((broken + 1))
    fi
  done
done
[[ $broken -eq 0 ]] && pass "all agent→skill citations resolve" || fail "agent→skill" "$broken broken"

# Agent citations of bin/ commands (exclude config files, agent names, and other non-bin tokens)
echo "--- Agents citing bin/ commands ---"
broken=0
for agent in agents/*.md; do
  # Match `claudehut-X` but exclude:
  # - followed by .json / .md / .sh / .yml (filenames)
  # - agent names (orchestrator, brainstormer, ...)
  for ref in $(grep -oE '\bclaudehut-[a-z-]+' "$agent" 2>/dev/null \
              | grep -vE '^claudehut-(orchestrator|brainstormer|spec-writer|planner|builder|verifier|learner|reuse-scanner|stack-detector|test-runner|migration-validator|reviewer-|config)' \
              | sort -u); do
    # Skip if followed by file extension in source
    if grep -qE "\b$ref\.(json|md|sh|yml|yaml)\b" "$agent"; then continue; fi
    if [[ ! -f "bin/$ref" ]]; then
      echo "  broken in $agent: $ref (no bin/$ref)"
      broken=$((broken + 1))
    fi
  done
done
[[ $broken -eq 0 ]] && pass "all agent→bin/ citations resolve" || fail "agent→bin" "$broken broken"

# rules-index.json entries
echo "--- rules-index.json ---"
broken=0
while IFS= read -r rule; do
  if [[ ! -f "$rule" ]]; then
    echo "  broken index entry: $rule"
    broken=$((broken + 1))
  fi
done < <(jq -r '.[].rule' rules/rules-index.json)
[[ $broken -eq 0 ]] && pass "all rules-index entries resolve" || fail "rules-index" "$broken broken"

# Rules in rules/ but not in rules-index.json (informational)
echo "--- Rules coverage in index (informational) ---"
unindexed=0
while IFS= read -r rule_file; do
  rule_rel="${rule_file#./}"
  if ! jq -r '.[].rule' rules/rules-index.json | grep -qF "$rule_rel"; then
    unindexed=$((unindexed + 1))
  fi
done < <(find ./rules -name '*.md')
if [[ $unindexed -eq 0 ]]; then
  pass "all 42 rules referenced in rules-index.json"
else
  fail "rules-index coverage" "$unindexed rule(s) not indexed"
fi

echo ""
echo "===== SUMMARY ====="
printf "Total: %d   \033[32mPass: %d\033[0m   \033[31mFail: %d\033[0m\n" $((PASS+FAIL)) "$PASS" "$FAIL"

if [[ "$FAIL" -gt 0 ]]; then
  echo ""
  echo "FAILURES:"
  for f in "${FAIL_LIST[@]}"; do echo "  - $f"; done
  exit 1
fi
exit 0
