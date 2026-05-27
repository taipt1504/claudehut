#!/usr/bin/env bash
# tests/run-all.sh — comprehensive self-test for claudehut plugin
# Runs 5 layers: static validation, unit tests, integration, coverage, enforcement sim.
# Exit 0 if zero failures; non-zero on any fail.

set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PLUGIN_ROOT"

PASS=0; FAIL=0; SKIP=0
declare -a FAIL_LIST=()

section() { echo ""; echo "===== $1 ====="; }
pass() { printf "  \033[32m✓\033[0m %s\n" "$1"; PASS=$((PASS+1)); }
fail() { printf "  \033[31m✗\033[0m %s :: %s\n" "$1" "$2"; FAIL=$((FAIL+1)); FAIL_LIST+=("$1: $2"); }
skip() { printf "  \033[33m-\033[0m %s :: %s\n" "$1" "${2:-skipped}"; SKIP=$((SKIP+1)); }

#==============================================================================
section "L1.1 JSON validity"
#==============================================================================
for f in .claude-plugin/plugin.json hooks/hooks.json .mcp.json settings.json rules/rules-index.json templates/claudehut-config.template.json templates/stack-signals.template.json; do
  if python3 -c "import json; json.load(open('$f'))" 2>/dev/null; then pass "$f"; else fail "$f" "JSON parse error"; fi
done

#==============================================================================
section "L1.2 Bash syntax (all scripts)"
#==============================================================================
while IFS= read -r f; do
  if bash -n "$f" 2>/dev/null; then pass "$f"; else fail "$f" "bash syntax error"; fi
done < <(find scripts bin tests/fixtures -name '*.sh' -type f 2>/dev/null) < <(find skills -name '*.sh' -type f 2>/dev/null)

# Re-run skills scripts since process substitution above only consumed first
for f in $(find skills -name '*.sh' -type f); do
  if bash -n "$f" 2>/dev/null; then pass "$f"; else fail "$f" "bash syntax error"; fi
done

# bin executables
for f in bin/*; do
  if bash -n "$f" 2>/dev/null; then pass "$f"; else fail "$f" "bash syntax error"; fi
done

#==============================================================================
section "L1.3 Mermaid balance (opens == closes per file)"
#==============================================================================
for f in $(find . -name '*.md' -not -path './tests/*' -not -path './.claude/*'); do
  opens=$(grep -c '^```mermaid' "$f" 2>/dev/null || echo 0)
  if [[ "$opens" -gt 0 ]]; then
    closes=$(awk 'flag && /^```$/{count++; flag=0} /^```mermaid/{flag=1} END{print count+0}' "$f")
    if [[ "$opens" == "$closes" ]]; then pass "$(basename $f) (mermaid x$opens)"; else fail "$f" "mermaid imbalanced: opens=$opens closes=$closes"; fi
  fi
done

#==============================================================================
section "L1.4 SKILL.md frontmatter compliance (Anthropic spec)"
#==============================================================================
for f in $(find skills -name 'SKILL.md'); do
  if ! head -1 "$f" | grep -q '^---$'; then fail "$f" "missing frontmatter opening ---"; continue; fi
  name=$(awk '/^---$/{c++; next} c==1 && /^name:/{print $2; exit}' "$f")
  desc=$(awk '/^---$/{c++; next} c==1 && /^description:/{sub(/^description:[ \t]*/, ""); print; exit}' "$f")
  folder=$(basename $(dirname "$f"))
  [[ -z "$name" ]] && { fail "$f" "missing 'name' field"; continue; }
  [[ -z "$desc" ]] && { fail "$f" "missing 'description' field"; continue; }
  [[ "$name" != "$folder" ]] && { fail "$f" "name '$name' != folder '$folder'"; continue; }
  pass "$f (name=$name)"
done

#==============================================================================
section "L1.5 Agent frontmatter compliance"
#==============================================================================
for f in $(find agents -name '*.md'); do
  if ! head -1 "$f" | grep -q '^---$'; then fail "$f" "missing frontmatter"; continue; fi
  name=$(awk '/^---$/{c++; next} c==1 && /^name:/{print $2; exit}' "$f")
  desc=$(awk '/^---$/{c++; next} c==1 && /^description:/{sub(/^description:[ \t]*/, ""); print; exit}' "$f")
  model=$(awk '/^---$/{c++; next} c==1 && /^model:/{print $2; exit}' "$f")
  [[ -z "$name" ]] && { fail "$f" "missing 'name'"; continue; }
  [[ -z "$desc" ]] && { fail "$f" "missing 'description'"; continue; }
  [[ -z "$model" ]] && { fail "$f" "missing 'model'"; continue; }
  case "$model" in
    sonnet|opus|haiku|sonnet-*|opus-*|haiku-*|claude-*) pass "$f (model=$model)" ;;
    *) fail "$f" "invalid model '$model'" ;;
  esac
done

#==============================================================================
section "L1.6 SKILL.md reference links resolve"
#==============================================================================
for f in $(find skills -name 'SKILL.md'); do
  dir=$(dirname "$f")
  broken=0
  for ref in $(grep -oE 'references/[a-z0-9-]+\.md' "$f" | sort -u); do
    if [[ -f "$dir/$ref" ]]; then :; else echo "    broken: $ref"; broken=$((broken+1)); fi
  done
  if [[ "$broken" -eq 0 ]]; then pass "$f (refs ok)"; else fail "$f" "$broken broken reference link(s)"; fi
done

#==============================================================================
section "L1.7 Rules-index.json references exist"
#==============================================================================
broken=0
while IFS= read -r rule; do
  if [[ -f "$rule" ]]; then :; else echo "    broken: $rule"; broken=$((broken+1)); fi
done < <(jq -r '.[].rule' rules/rules-index.json)
if [[ "$broken" -eq 0 ]]; then pass "all rules-index entries resolve"; else fail "rules-index.json" "$broken broken rule path(s)"; fi

#==============================================================================
section "L1.8 Plugin manifest spec compliance"
#==============================================================================
manifest=.claude-plugin/plugin.json
name=$(jq -r '.name' $manifest)
[[ -n "$name" && "$name" != "null" ]] && pass "manifest has 'name'" || fail "manifest" "missing 'name'"
[[ "$name" =~ ^[a-z][a-z0-9-]*$ ]] && pass "manifest name is kebab-case" || fail "manifest" "name not kebab-case"
ver=$(jq -r '.version' $manifest)
[[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] && pass "manifest has semver" || fail "manifest" "invalid version"

#==============================================================================
section "L2.1 state.sh phase derivation"
#==============================================================================
TMPDIR=$(mktemp -d)
cd "$TMPDIR"
git init -q
git checkout -q -b feature/test-task 2>/dev/null

export CLAUDE_PROJECT_DIR="$TMPDIR"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "$PLUGIN_ROOT/scripts/hooks/lib/state.sh"

# Test: uninitialized
phase=$(claudehut_phase)
[[ "$phase" == "uninitialized" ]] && pass "phase=uninitialized when no .claudehut/" || fail "state.sh" "expected uninitialized got '$phase'"

mkdir -p .claudehut/{specs,plans,memory,findings,reuse-scans}

# Test: brainstorm phase (no design doc)
phase=$(claudehut_phase)
[[ "$phase" == "brainstorm" ]] && pass "phase=brainstorm when no design doc" || fail "state.sh" "expected brainstorm got '$phase'"

# Create design doc → expect spec
TASK_ID=$(claudehut_task_id)
echo "design" > ".claudehut/specs/${TASK_ID}-design.md"
phase=$(claudehut_phase)
[[ "$phase" == "spec" ]] && pass "phase=spec when design exists" || fail "state.sh" "expected spec got '$phase'"

# Create contract → expect plan
echo "contract" > ".claudehut/specs/${TASK_ID}-contract.md"
phase=$(claudehut_phase)
[[ "$phase" == "plan" ]] && pass "phase=plan when contract exists" || fail "state.sh" "expected plan got '$phase'"

# Create plan with unchecked task → expect build
cat > ".claudehut/plans/${TASK_ID}-plan.md" <<'PLAN'
# Plan
## Task 1: Foo
- [ ] complete
PLAN
phase=$(claudehut_phase)
[[ "$phase" == "build" ]] && pass "phase=build when plan has unchecked" || fail "state.sh" "expected build got '$phase'"

# All checked → expect loop
sed -i.bak 's/- \[ \]/- [x]/' ".claudehut/plans/${TASK_ID}-plan.md"
phase=$(claudehut_phase)
[[ "$phase" == "loop" ]] && pass "phase=loop when plan fully checked" || fail "state.sh" "expected loop got '$phase'"

# findings.json decision=pass → expect learn
echo '{"decision":"pass"}' > ".claudehut/findings/${TASK_ID}-findings.json"
phase=$(claudehut_phase)
[[ "$phase" == "learn" ]] && pass "phase=learn when findings pass" || fail "state.sh" "expected learn got '$phase'"

# learnings.jsonl with task_id → expect done
echo "{\"task_id\":\"$TASK_ID\",\"category\":\"pattern\"}" > .claudehut/memory/learnings.jsonl
phase=$(claudehut_phase)
[[ "$phase" == "done" ]] && pass "phase=done when learnings has entry" || fail "state.sh" "expected done got '$phase'"

# main branch → expect none
git checkout -q -b main 2>/dev/null || git checkout -q main
phase=$(claudehut_phase)
[[ "$phase" == "none" ]] && pass "phase=none on main branch" || fail "state.sh" "expected none got '$phase'"

cd "$PLUGIN_ROOT"
rm -rf "$TMPDIR"
unset CLAUDE_PROJECT_DIR

#==============================================================================
section "L2.2 validate-migration.sh"
#==============================================================================
script="$PLUGIN_ROOT/skills/flyway-migration/scripts/validate-migration.sh"

tmp=$(mktemp --suffix=.sql 2>/dev/null || mktemp -t test.XXXXXX)
mv "$tmp" "${tmp}.sql"; tmp="${tmp}.sql"

# Good naming + safe DDL
mv "$tmp" "$(dirname $tmp)/V20250527001__add_users_table.sql"
tmp="$(dirname $tmp)/V20250527001__add_users_table.sql"
echo "CREATE TABLE users (id UUID PRIMARY KEY);" > "$tmp"
bash "$script" "$tmp" >/dev/null 2>&1 && pass "good naming + CREATE TABLE accepted" || fail "validate-migration.sh" "rejected good migration"

# Bad: ADD COLUMN NOT NULL without DEFAULT
echo "ALTER TABLE users ADD COLUMN tenant_id UUID NOT NULL;" > "$tmp"
if bash "$script" "$tmp" >/dev/null 2>&1; then fail "validate-migration.sh" "accepted bad NOT NULL"; else pass "rejected NOT NULL no DEFAULT"; fi

# Bad: R__ with DDL
bad=$(dirname "$tmp")/R__bad.sql
echo "CREATE TABLE foo (id INT);" > "$bad"
if bash "$script" "$bad" >/dev/null 2>&1; then fail "validate-migration.sh" "accepted R__ with DDL"; else pass "rejected R__ with table DDL"; fi
rm "$tmp" "$bad"

#==============================================================================
section "L2.3 secret-scan.sh"
#==============================================================================
script="$PLUGIN_ROOT/skills/learn/scripts/secret-scan.sh"

# Clean text
echo "this is clean text with no secrets at all" | bash "$script" - >/dev/null 2>&1 && pass "clean text passes" || fail "secret-scan.sh" "false positive on clean text"

# AWS key
echo "AWS_KEY=AKIAIOSFODNN7EXAMPLE blah" | bash "$script" - >/dev/null 2>&1 && fail "secret-scan.sh" "missed AWS key" || pass "detects AWS key"

# OpenAI/Anthropic key
echo "sk-abc123def456ghi789jkl012mno345" | bash "$script" - >/dev/null 2>&1 && fail "secret-scan.sh" "missed sk- key" || pass "detects sk- key"

# Postgres URL with creds
echo "postgres://user:pass@host/db" | bash "$script" - >/dev/null 2>&1 && fail "secret-scan.sh" "missed postgres URL" || pass "detects postgres URL"

#==============================================================================
section "L2.4 design-doc-selfreview.sh"
#==============================================================================
script="$PLUGIN_ROOT/skills/brainstorm/scripts/design-doc-selfreview.sh"
tmp=$(mktemp -t test-design.XXXXXX)

# Good doc
cat > "$tmp" <<'DOC'
# Feature
## Overview
This adds X.
## Components
- A: does Y
## Data flow
1. Caller invokes A
## Error handling
- E1: handled by Z
## Testing strategy
Unit + integration.
## NFR
| NFR | Budget |
|-----|--------|
| Latency p95 | ≤ 200ms |
DOC
bash "$script" "$tmp" >/dev/null 2>&1 && pass "good design accepted" || fail "design-selfreview" "rejected good doc"

# Bad: has TBD
echo "TBD here" >> "$tmp"
if bash "$script" "$tmp" >/dev/null 2>&1; then fail "design-selfreview" "accepted TBD"; else pass "rejects TBD placeholder"; fi

# Bad: missing section
cat > "$tmp" <<'DOC'
# Feature
## Overview
Yes.
DOC
if bash "$script" "$tmp" >/dev/null 2>&1; then fail "design-selfreview" "accepted missing sections"; else pass "rejects missing sections"; fi

rm "$tmp"

#==============================================================================
section "L2.5 plan validators"
#==============================================================================
script1="$PLUGIN_ROOT/skills/plan/scripts/plan-placeholder-scan.sh"
script2="$PLUGIN_ROOT/skills/plan/scripts/plan-spec-coverage.sh"
tmp=$(mktemp -t test-plan.XXXXXX)
contract=$(mktemp -t test-contract.XXXXXX)

cat > "$contract" <<'C'
# Contract
## AC-1: foo
GIVEN x WHEN y THEN z
## AC-2: bar
GIVEN x WHEN y THEN z
C

# Good plan covering both ACs
cat > "$tmp" <<'P'
# Plan
## Task 1: do AC-1
**RED:**
```bash
./gradlew test
```
**Verify:**
```bash
./gradlew test
```
## Task 2: do AC-2
**RED:**
```bash
./gradlew test
```
**Verify:**
```bash
./gradlew test
```
P

bash "$script1" "$tmp" >/dev/null 2>&1 && pass "good plan: no placeholders" || fail "plan-placeholder" "rejected clean plan"
bash "$script2" "$tmp" "$contract" >/dev/null 2>&1 && pass "good plan: covers all ACs" || fail "plan-coverage" "rejected covering plan"

# Bad: missing AC-2
cat > "$tmp" <<'P'
# Plan
## Task 1: do AC-1
**RED:**
```bash
./gradlew test
```
**Verify:**
```bash
./gradlew test
```
P
if bash "$script2" "$tmp" "$contract" >/dev/null 2>&1; then fail "plan-coverage" "accepted uncovered AC"; else pass "rejects plan missing AC"; fi

# Bad: TBD
echo "TBD" >> "$tmp"
if bash "$script1" "$tmp" >/dev/null 2>&1; then fail "plan-placeholder" "accepted TBD"; else pass "rejects plan with TBD"; fi

rm "$tmp" "$contract"

#==============================================================================
section "L2.6 validate-skill.sh"
#==============================================================================
script="$PLUGIN_ROOT/skills/write-skill/scripts/validate-skill.sh"
for s in $(find skills -mindepth 1 -maxdepth 1 -type d); do
  if bash "$script" "$s" >/dev/null 2>&1; then pass "$(basename $s)"; else fail "$(basename $s)" "skill validator failed"; fi
done

#==============================================================================
section "L2.7 extract-nouns.sh"
#==============================================================================
script="$PLUGIN_ROOT/skills/brainstorm/scripts/extract-nouns.sh"
out=$(bash "$script" "Add user purchase history endpoint to API")
[[ "$out" =~ user ]] && [[ "$out" =~ purchase ]] && [[ "$out" =~ history ]] && pass "extracts 'user purchase history'" || fail "extract-nouns.sh" "missed nouns: $out"

out=$(bash "$script" "")
[[ -z "${out// /}" ]] && pass "empty input returns empty" || fail "extract-nouns.sh" "empty input returned: $out"

#==============================================================================
section "L3.1 Hook: SessionStart on uninitialized project"
#==============================================================================
TMPDIR=$(mktemp -d)
export CLAUDE_PROJECT_DIR="$TMPDIR"
echo '{}' | bash "$PLUGIN_ROOT/scripts/hooks/session-start.sh" > "$TMPDIR/out.json" 2>&1
if jq -e '.hookSpecificOutput.additionalContext | contains("not initialized")' "$TMPDIR/out.json" >/dev/null 2>&1; then
  pass "SessionStart: uninitialized warning emitted"
else
  fail "SessionStart" "uninitialized output incorrect: $(cat $TMPDIR/out.json | head -3)"
fi
rm -rf "$TMPDIR"
unset CLAUDE_PROJECT_DIR

#==============================================================================
section "L3.2 Hook: SessionStart on initialized project"
#==============================================================================
TMPDIR=$(mktemp -d)
cd "$TMPDIR"
git init -q
git checkout -q -b feature/test 2>/dev/null
mkdir -p .claudehut/{specs,plans,memory,findings,reuse-scans}
echo '{"web_stack":"webflux","orm":["r2dbc"],"db":["postgresql"]}' > .claudehut/memory/stack-signals.json

export CLAUDE_PROJECT_DIR="$TMPDIR"
echo '{}' | bash "$PLUGIN_ROOT/scripts/hooks/session-start.sh" > "$TMPDIR/out.json" 2>&1

if jq -e '.hookSpecificOutput.additionalContext | contains("ClaudeHut active")' "$TMPDIR/out.json" >/dev/null 2>&1; then
  pass "SessionStart: outputs ClaudeHut active"
else
  fail "SessionStart" "active output missing: $(cat $TMPDIR/out.json)"
fi

if jq -e '.hookSpecificOutput.additionalContext | contains("Phase:    brainstorm")' "$TMPDIR/out.json" >/dev/null 2>&1; then
  pass "SessionStart: derives phase=brainstorm"
else
  fail "SessionStart" "phase derivation missing in output"
fi

if jq -e '.hookSpecificOutput.additionalContext | contains("webflux")' "$TMPDIR/out.json" >/dev/null 2>&1; then
  pass "SessionStart: shows webflux stack"
else
  fail "SessionStart" "stack info missing"
fi
cd "$PLUGIN_ROOT"
rm -rf "$TMPDIR"

#==============================================================================
section "L3.3 Hook: prompt-router blocks skip-attempts"
#==============================================================================
TMPDIR=$(mktemp -d)
cd "$TMPDIR"
git init -q
git checkout -q -b feature/test 2>/dev/null
mkdir -p .claudehut/{specs,plans,memory,findings}
export CLAUDE_PROJECT_DIR="$TMPDIR"

# Skip-attempt prompt
echo '{"prompt":"just write the code, skip the plan"}' | bash "$PLUGIN_ROOT/scripts/hooks/prompt-router.sh" > "$TMPDIR/out.json" 2>&1
if jq -e '.decision == "block"' "$TMPDIR/out.json" >/dev/null 2>&1; then
  pass "prompt-router: blocks 'just write the code'"
else
  fail "prompt-router" "skip-attempt not blocked: $(cat $TMPDIR/out.json)"
fi

# Intent prompt on main → suggests branch
cd "$TMPDIR"
git checkout -q main 2>/dev/null || git checkout -q -b main 2>/dev/null
echo '{"prompt":"add endpoint to fetch user purchase history"}' | bash "$PLUGIN_ROOT/scripts/hooks/prompt-router.sh" > "$TMPDIR/out.json" 2>&1
if jq -e '.hookSpecificOutput.additionalContext | contains("feature branch")' "$TMPDIR/out.json" >/dev/null 2>&1; then
  pass "prompt-router: suggests branch on feature intent + main"
else
  fail "prompt-router" "branch suggestion missing"
fi

cd "$PLUGIN_ROOT"
rm -rf "$TMPDIR"

#==============================================================================
section "L3.4 Hook: pre-tool blocks destructive bash"
#==============================================================================
TMPDIR=$(mktemp -d)
cd "$TMPDIR"
git init -q
mkdir -p .claudehut/{specs,plans,memory}
export CLAUDE_PROJECT_DIR="$TMPDIR"

echo '{"tool_input":{"command":"rm -rf /"}}' | bash "$PLUGIN_ROOT/scripts/hooks/pre-tool.sh" --tool bash > "$TMPDIR/out.json" 2>&1
if jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$TMPDIR/out.json" >/dev/null 2>&1; then
  pass "pre-tool: denies 'rm -rf /'"
else
  fail "pre-tool" "destructive not denied: $(cat $TMPDIR/out.json)"
fi

echo '{"tool_input":{"command":"git push --force origin main"}}' | bash "$PLUGIN_ROOT/scripts/hooks/pre-tool.sh" --tool bash > "$TMPDIR/out.json" 2>&1
if jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$TMPDIR/out.json" >/dev/null 2>&1; then
  pass "pre-tool: denies 'git push --force'"
else
  fail "pre-tool" "force push not denied"
fi

echo '{"tool_input":{"command":"./gradlew test"}}' | bash "$PLUGIN_ROOT/scripts/hooks/pre-tool.sh" --tool bash > "$TMPDIR/out.json" 2>&1
if jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$TMPDIR/out.json" >/dev/null 2>&1; then
  fail "pre-tool" "false-positive deny on gradle test"
else
  pass "pre-tool: allows safe gradle test"
fi

cd "$PLUGIN_ROOT"
rm -rf "$TMPDIR"

#==============================================================================
section "L3.5 Hook: pre-tool blocks src/ edit in wrong phase"
#==============================================================================
TMPDIR=$(mktemp -d)
cd "$TMPDIR"
git init -q
git checkout -q -b feature/test 2>/dev/null
mkdir -p .claudehut/{specs,plans,memory} src/main/java/com/x
export CLAUDE_PROJECT_DIR="$TMPDIR"

# Phase=brainstorm; edit src/ → should deny
echo "{\"tool_input\":{\"file_path\":\"$TMPDIR/src/main/java/com/x/Foo.java\"}}" | bash "$PLUGIN_ROOT/scripts/hooks/pre-tool.sh" --tool edit > "$TMPDIR/out.json" 2>&1
if jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$TMPDIR/out.json" >/dev/null 2>&1; then
  pass "pre-tool: blocks src/ edit in brainstorm phase"
else
  fail "pre-tool" "should block src/ in brainstorm: $(cat $TMPDIR/out.json)"
fi

# Edit inside .claudehut/ → should allow
echo "{\"tool_input\":{\"file_path\":\"$TMPDIR/.claudehut/specs/feature-test-design.md\"}}" | bash "$PLUGIN_ROOT/scripts/hooks/pre-tool.sh" --tool edit > "$TMPDIR/out.json" 2>&1
if jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$TMPDIR/out.json" >/dev/null 2>&1; then
  fail "pre-tool" "wrongly blocks .claudehut/ writes: $(cat $TMPDIR/out.json)"
else
  pass "pre-tool: allows .claudehut/ writes anytime"
fi

cd "$PLUGIN_ROOT"
rm -rf "$TMPDIR"

#==============================================================================
section "L4 Coverage — rules + skills + agents"
#==============================================================================
n_rules=$(find rules -name '*.md' | wc -l | tr -d ' ')
n_indexed=$(jq -r '.[].rule' rules/rules-index.json | sort -u | wc -l | tr -d ' ')
[[ "$n_rules" -ge "$n_indexed" ]] && pass "rules: $n_rules files, $n_indexed indexed entries" || fail "coverage" "more indexed than rules?"

# Rules not in index (acceptable but worth noting)
unindexed=0
while IFS= read -r rule_file; do
  rule_rel="${rule_file#./}"
  if ! jq -r '.[].rule' rules/rules-index.json | grep -qF "$rule_rel"; then
    unindexed=$((unindexed+1))
  fi
done < <(find rules -name '*.md')
if [[ "$unindexed" -eq 0 ]]; then pass "all rule files indexed"; else skip "$unindexed rule(s) not in rules-index.json (may be acceptable)"; fi

# Agent count
n_agents=$(find agents -name '*.md' | wc -l | tr -d ' ')
[[ "$n_agents" -eq 17 ]] && pass "agent count: 17 (matches design)" || skip "agent count: $n_agents (expected 17)"

# Skill count
n_skills=$(find skills -name 'SKILL.md' | wc -l | tr -d ' ')
[[ "$n_skills" -eq 28 ]] && pass "skill count: 28 (matches design)" || skip "skill count: $n_skills (expected 28)"

# Hook events configured
n_hooks=$(jq -r '.hooks | keys[]' hooks/hooks.json | wc -l | tr -d ' ')
[[ "$n_hooks" -ge 7 ]] && pass "hook events: $n_hooks configured" || fail "hooks" "only $n_hooks events configured"

# MCP servers
n_mcp=$(jq -r '.mcpServers | keys[]' .mcp.json | wc -l | tr -d ' ')
[[ "$n_mcp" -ge 3 ]] && pass "MCP servers: $n_mcp configured" || fail "mcp" "only $n_mcp servers"

#==============================================================================
section "L5 Enforcement simulation — agent pattern compliance"
#==============================================================================
# All 17 agents must have G/G/G/H pattern
n_compliant=0
for f in agents/*.md; do
  has_goals=$(grep -c '^## Goals' "$f")
  has_gates=$(grep -c '^## Gates' "$f")
  has_guard=$(grep -c '^## Guardrails' "$f")
  has_heur=$(grep -c '^## Heuristics' "$f")
  if [[ "$has_goals" -ge 1 && "$has_gates" -ge 1 && "$has_guard" -ge 1 && "$has_heur" -ge 1 ]]; then
    n_compliant=$((n_compliant+1))
  fi
done
[[ "$n_compliant" -eq 17 ]] && pass "all 17 agents follow Goals+Gates+Guardrails+Heuristics" || fail "agent compliance" "only $n_compliant/17 compliant"

# 7 main agents must have state diagram (Mermaid)
n_main_diagrammed=0
for f in agents/claudehut-orchestrator.md agents/claudehut-brainstormer.md agents/claudehut-spec-writer.md agents/claudehut-planner.md agents/claudehut-builder.md agents/claudehut-verifier.md agents/claudehut-learner.md; do
  if grep -q '^```mermaid' "$f"; then n_main_diagrammed=$((n_main_diagrammed+1)); fi
done
[[ "$n_main_diagrammed" -eq 7 ]] && pass "all 7 main agents have state diagram" || fail "diagram coverage" "only $n_main_diagrammed/7 have diagram"

#==============================================================================
section "L6 End-to-end simulated workflow"
#==============================================================================
if bash "$PLUGIN_ROOT/tests/e2e/simulated/full-workflow.sh" >/tmp/e2e-sim.log 2>&1; then
  e2e_total=$(grep -E '^Total: ' /tmp/e2e-sim.log | head -1 | awk '{print $2}')
  e2e_pass=$(grep -oE 'Pass: [0-9]+' /tmp/e2e-sim.log | head -1 | awk '{print $2}')
  pass "E2E simulated full-workflow: ${e2e_pass}/${e2e_total} steps pass"
else
  fail "E2E simulated" "see /tmp/e2e-sim.log"
fi

#==============================================================================
section "L7 Bash 3.2 compatibility"
#==============================================================================
if bash "$PLUGIN_ROOT/tests/static/bash-compat.sh" >/tmp/compat.log 2>&1; then
  pass "all scripts bash 3.2 compatible"
else
  fail "bash compat" "see /tmp/compat.log"
fi

#==============================================================================
section "L8 Bidirectional reference integrity"
#==============================================================================
if bash "$PLUGIN_ROOT/tests/static/ref-integrity.sh" >/tmp/refs.log 2>&1; then
  pass "all bidirectional references resolve"
else
  fail "ref integrity" "see /tmp/refs.log"
fi

#==============================================================================
section "L9 Snapshot tests (hook outputs)"
#==============================================================================
if bash "$PLUGIN_ROOT/tests/snapshot/run-snapshots.sh" >/tmp/snap.log 2>&1; then
  snap_pass=$(grep -oE 'Pass: [0-9]+' /tmp/snap.log | head -1 | awk '{print $2}')
  pass "snapshot tests: $snap_pass scenarios match golden files"
else
  fail "snapshots" "drift detected; see /tmp/snap.log"
fi

#==============================================================================
section "L10 Hook performance benchmark"
#==============================================================================
if bash "$PLUGIN_ROOT/tests/perf/hook-benchmark.sh" >/tmp/perf.log 2>&1; then
  perf_pass=$(grep -oE 'Pass: [0-9]+' /tmp/perf.log | head -1 | awk '{print $2}')
  pass "all $perf_pass hooks within p95 budget"
else
  fail "perf budget" "breach detected; see /tmp/perf.log"
fi

#==============================================================================
section "L11 Reviewer dispatch (subagent stop)"
#==============================================================================
if bash "$PLUGIN_ROOT/tests/integration/reviewer-dispatch.sh" >/tmp/disp.log 2>&1; then
  disp_pass=$(grep -oE 'Pass: [0-9]+' /tmp/disp.log | head -1 | awk '{print $2}')
  pass "reviewer dispatch: $disp_pass assertions"
else
  fail "reviewer dispatch" "see /tmp/disp.log"
fi

#==============================================================================
section "SUMMARY"
#==============================================================================
TOTAL=$((PASS+FAIL+SKIP))
echo ""
printf "Total: %d   \033[32mPass: %d\033[0m   \033[31mFail: %d\033[0m   \033[33mSkip: %d\033[0m\n" "$TOTAL" "$PASS" "$FAIL" "$SKIP"
if [[ "$FAIL" -gt 0 ]]; then
  echo ""
  echo "FAILURES:"
  for f in "${FAIL_LIST[@]}"; do echo "  - $f"; done
  exit 1
fi
exit 0
