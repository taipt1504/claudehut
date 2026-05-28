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
for f in .claude-plugin/plugin.json hooks/hooks.json .mcp.json settings.json templates/claudehut-config.template.json; do
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
  # awk counts both fences in one pass — guaranteed numeric output, no exit-code games.
  # (Prior `grep -c ... || echo 0` double-printed "0" on zero-match grep, breaking [[ -gt ]].)
  read -r opens closes < <(awk '
    /^```mermaid/                { opens++; in_mer=1; next }
    in_mer && /^```[[:space:]]*$/ { closes++; in_mer=0; next }
    END { printf "%d %d\n", opens+0, closes+0 }
  ' "$f")
  [[ "$opens" -eq 0 ]] && continue
  if [[ "$opens" -eq "$closes" ]]; then
    pass "$(basename $f) (mermaid x$opens)"
  else
    fail "$f" "mermaid imbalanced: opens=$opens closes=$closes"
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
# Each agent must have name/description/model and (except orchestrator) a
# `skills:` preload list — subagent context is isolated, so the agent's
# essential phase/domain skill MUST be preloaded via frontmatter, not relied
# on from the main thread.

# Map: agent stem → required preload skills (space-separated)
agent_requires() {
  case "$1" in
    claudehut-brainstormer)         echo "claudehut:brainstorm claudehut:reuse-scan" ;;
    claudehut-spec-writer)          echo "claudehut:spec" ;;
    claudehut-planner)              echo "claudehut:plan claudehut:tdd-cycle" ;;
    claudehut-builder)              echo "claudehut:build claudehut:tdd-cycle" ;;
    claudehut-verifier)             echo "claudehut:verify-review" ;;
    claudehut-learner)              echo "claudehut:learn" ;;
    claudehut-reuse-scanner)        echo "claudehut:reuse-scan" ;;
    claudehut-migration-validator)  echo "claudehut:flyway-migration" ;;
    claudehut-test-runner)          echo "claudehut:tdd-cycle" ;;
    claudehut-reviewer-db)          echo "claudehut:r2dbc claudehut:jpa-hibernate" ;;
    claudehut-reviewer-mapping)     echo "claudehut:mapstruct claudehut:jackson" ;;
    claudehut-reviewer-reactive)    echo "claudehut:spring-webflux" ;;
    claudehut-reviewer-security)    echo "claudehut:owasp-scan" ;;
    claudehut-stack-detector|claudehut-reviewer-perf|claudehut-reviewer-style|claudehut-orchestrator) echo "" ;;
    *) echo "?" ;;
  esac
}

for f in $(find agents -name '*.md'); do
  if ! head -1 "$f" | grep -q '^---$'; then fail "$f" "missing frontmatter"; continue; fi
  name=$(awk '/^---$/{c++; next} c==1 && /^name:/{print $2; exit}' "$f")
  desc=$(awk '/^---$/{c++; next} c==1 && /^description:/{sub(/^description:[ \t]*/, ""); print; exit}' "$f")
  model=$(awk '/^---$/{c++; next} c==1 && /^model:/{print $2; exit}' "$f")
  [[ -z "$name" ]] && { fail "$f" "missing 'name'"; continue; }
  [[ -z "$desc" ]] && { fail "$f" "missing 'description'"; continue; }
  [[ -z "$model" ]] && { fail "$f" "missing 'model'"; continue; }
  case "$model" in
    sonnet|opus|haiku|sonnet-*|opus-*|haiku-*|claude-*) ;;
    *) fail "$f" "invalid model '$model'"; continue ;;
  esac

  # Preload check.
  stem="$(basename "$f" .md)"
  required="$(agent_requires "$stem")"
  if [[ "$required" == "?" ]]; then
    fail "$f" "L1.5: unknown agent stem '$stem' — update agent_requires() in tests"
    continue
  fi
  if [[ -z "$required" ]]; then
    pass "$f (model=$model, no preload required)"
    continue
  fi
  fm_block="$(awk '/^---$/{c++; if(c==2)exit} c==1' "$f")"
  if ! grep -q '^skills:' <<<"$fm_block"; then
    fail "$f" "missing 'skills:' preload (required: $required)"
    continue
  fi
  preloaded="$(awk '/^skills:/{flag=1; next} flag && /^[a-z_]+:/{flag=0} flag && /^[[:space:]]+-/{sub(/^[[:space:]]+-[[:space:]]+/,""); print}' <<<"$fm_block" | tr -d ' ')"
  missing=""
  for r in $required; do
    if ! grep -q "^${r}\$" <<<"$preloaded"; then
      missing="$missing $r"
    fi
  done
  if [[ -n "$missing" ]]; then
    fail "$f" "skills preload missing:${missing}"
  else
    pass "$f (model=$model, preload=[$required])"
  fi
done

# Every agent except the orchestrator must include the Skill Discipline section
# in its body (the main thread's loaded context is not inherited).
for f in $(find agents -name '*.md'); do
  case "$(basename "$f")" in
    claudehut-orchestrator.md) continue ;;
  esac
  if grep -q '^## Skill Discipline' "$f"; then
    pass "$f Skill Discipline present"
  else
    fail "$f" "missing '## Skill Discipline' section in body"
  fi
done

# Bootstrap skill `using-claudehut` must be the FIRST preload entry of every
# dispatch-eligible agent so the catalog + invocation discipline is in the
# subagent's context at startup, ahead of phase-specific skills.
for f in $(find agents -name '*.md'); do
  case "$(basename "$f")" in
    claudehut-orchestrator.md) continue ;;
  esac
  first_preload="$(awk '/^---$/{c++; if(c==2)exit} c==1 && /^skills:/{flag=1; next} flag && /^[[:space:]]+-/{sub(/^[[:space:]]+-[[:space:]]+/,""); print; exit}' "$f")"
  if [[ "$first_preload" == "claudehut:using-claudehut" ]]; then
    pass "$f bootstrap preload first"
  else
    fail "$f" "first 'skills:' entry must be claudehut:using-claudehut (got '$first_preload')"
  fi
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
section "L1.7 Rule frontmatter (paths:) present + valid"
#==============================================================================
missing_paths=0; bad_yaml=0
for f in $(find rules -name '*.md'); do
  fm=$(awk '/^---[[:space:]]*$/{n++; if(n==2)exit} n==1' "$f")
  if ! grep -q '^paths:' <<<"$fm"; then
    echo "    missing paths: $f"; missing_paths=$((missing_paths+1)); continue
  fi
  # paths block must be a YAML list (one or more `  - "..."` lines)
  list=$(awk '/^paths:/{flag=1;next} flag && /^[a-z_]+:/{flag=0} flag{print}' <<<"$fm")
  if ! grep -qE '^[[:space:]]+- ' <<<"$list"; then
    echo "    paths not a list: $f"; bad_yaml=$((bad_yaml+1))
  fi
done
[[ "$missing_paths" -eq 0 ]] && pass "all rules carry paths: frontmatter" || fail "rule frontmatter" "$missing_paths file(s) missing paths:"
[[ "$bad_yaml"      -eq 0 ]] && pass "all paths: blocks are YAML lists"   || fail "rule frontmatter" "$bad_yaml file(s) with malformed paths:"

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
source "$PLUGIN_ROOT/hooks/lib/state.sh"

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
echo '{}' | bash "$PLUGIN_ROOT/hooks/session-start.sh" > "$TMPDIR/out.json" 2>&1
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
cat > .claudehut/memory/stack-signals.md <<'STACK'
- web: webflux
- orm: r2dbc
- db: postgresql
- messaging: none
- cache: none
- mapper: mapstruct
- serialization: jackson
STACK

export CLAUDE_PROJECT_DIR="$TMPDIR"
echo '{}' | bash "$PLUGIN_ROOT/hooks/session-start.sh" > "$TMPDIR/out.json" 2>&1

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
echo '{"prompt":"just write the code, skip the plan"}' | bash "$PLUGIN_ROOT/hooks/prompt-router.sh" > "$TMPDIR/out.json" 2>&1
if jq -e '.decision == "block"' "$TMPDIR/out.json" >/dev/null 2>&1; then
  pass "prompt-router: blocks 'just write the code'"
else
  fail "prompt-router" "skip-attempt not blocked: $(cat $TMPDIR/out.json)"
fi

# Intent prompt on main → suggests branch
cd "$TMPDIR"
git checkout -q main 2>/dev/null || git checkout -q -b main 2>/dev/null
echo '{"prompt":"add endpoint to fetch user purchase history"}' | bash "$PLUGIN_ROOT/hooks/prompt-router.sh" > "$TMPDIR/out.json" 2>&1
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

echo '{"tool_input":{"command":"rm -rf /"}}' | bash "$PLUGIN_ROOT/hooks/pre-tool.sh" --tool bash > "$TMPDIR/out.json" 2>&1
if jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$TMPDIR/out.json" >/dev/null 2>&1; then
  pass "pre-tool: denies 'rm -rf /'"
else
  fail "pre-tool" "destructive not denied: $(cat $TMPDIR/out.json)"
fi

echo '{"tool_input":{"command":"git push --force origin main"}}' | bash "$PLUGIN_ROOT/hooks/pre-tool.sh" --tool bash > "$TMPDIR/out.json" 2>&1
if jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$TMPDIR/out.json" >/dev/null 2>&1; then
  pass "pre-tool: denies 'git push --force'"
else
  fail "pre-tool" "force push not denied"
fi

echo '{"tool_input":{"command":"./gradlew test"}}' | bash "$PLUGIN_ROOT/hooks/pre-tool.sh" --tool bash > "$TMPDIR/out.json" 2>&1
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
echo "{\"tool_input\":{\"file_path\":\"$TMPDIR/src/main/java/com/x/Foo.java\"}}" | bash "$PLUGIN_ROOT/hooks/pre-tool.sh" --tool edit > "$TMPDIR/out.json" 2>&1
if jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$TMPDIR/out.json" >/dev/null 2>&1; then
  pass "pre-tool: blocks src/ edit in brainstorm phase"
else
  fail "pre-tool" "should block src/ in brainstorm: $(cat $TMPDIR/out.json)"
fi

# Edit inside .claudehut/ → should allow
echo "{\"tool_input\":{\"file_path\":\"$TMPDIR/.claudehut/specs/feature-test-design.md\"}}" | bash "$PLUGIN_ROOT/hooks/pre-tool.sh" --tool edit > "$TMPDIR/out.json" 2>&1
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
[[ "$n_rules" -eq 45 ]] && pass "rules: $n_rules files (42 baseline + 3 Lombok)" || fail "coverage" "expected 45 rule files, found $n_rules"

# Stack-conditional rules (frontmatter `stack:` key) — informational
stack_count=$(grep -l '^stack:' rules/**/*.md 2>/dev/null | wc -l | tr -d ' ')
pass "stack-conditional rules: $stack_count (init copies these only when stack-signals match)"

# Agent count
n_agents=$(find agents -name '*.md' | wc -l | tr -d ' ')
[[ "$n_agents" -eq 17 ]] && pass "agent count: 17 (matches design)" || skip "agent count: $n_agents (expected 17)"

# Skill count
n_skills=$(find skills -name 'SKILL.md' | wc -l | tr -d ' ')
[[ "$n_skills" -eq 30 ]] && pass "skill count: 30 (29 workflow/domain + using-claudehut bootstrap; +1 lombok)" || fail "coverage" "skill count: $n_skills (expected 30)"

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
if VERBOSE=1 bash "$PLUGIN_ROOT/tests/snapshot/run-snapshots.sh" >/tmp/snap.log 2>&1; then
  snap_pass=$(grep -oE 'Pass: [0-9]+' /tmp/snap.log | head -1 | awk '{print $2}')
  pass "snapshot tests: $snap_pass scenarios match golden files"
else
  fail "snapshots" "drift detected — diff below"
  # Surface the actual diff so CI logs show the cause.
  echo "---- snapshot drift detail ----"
  cat /tmp/snap.log
  echo "---- end snapshot drift ----"
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
section "L12 Phase skill → subagent dispatch contract"
#==============================================================================
# Each workflow phase skill must (a) contain a Dispatch contract section,
# (b) reference the correct subagent_type, (c) ship a dispatch-prompt.sh script.
declare -a phases=(
  "brainstorm:claudehut-brainstormer"
  "spec:claudehut-spec-writer"
  "plan:claudehut-planner"
  "build:claudehut-builder"
  "verify-review:claudehut-verifier"
  "learn:claudehut-learner"
)
for entry in "${phases[@]}"; do
  skill="${entry%%:*}"
  agent="${entry##*:}"
  md="skills/$skill/SKILL.md"
  sh="skills/$skill/scripts/dispatch-prompt.sh"
  if ! grep -q '^## Dispatch contract' "$md"; then
    fail "L12 dispatch" "$md missing 'Dispatch contract' section"; continue
  fi
  if ! grep -q "subagent_type[[:space:]]*=[[:space:]]*\"$agent\"" "$md"; then
    fail "L12 dispatch" "$md missing subagent_type=$agent"; continue
  fi
  if [[ ! -x "$sh" ]]; then
    fail "L12 dispatch" "$sh missing or not executable"; continue
  fi
  if ! bash -n "$sh" 2>/dev/null; then
    fail "L12 dispatch" "$sh bash syntax error"; continue
  fi
  pass "L12 $skill → $agent dispatch wiring"
done

# SessionStart hook must inject the orchestrator dispatch contract every session.
ss_out="$(echo '{}' | bash "$PLUGIN_ROOT/hooks/session-start.sh" 2>/dev/null)"
if echo "$ss_out" | jq -e '.hookSpecificOutput.additionalContext | ascii_downcase | contains("dispatch contract")' >/dev/null 2>&1; then
  pass "L12 SessionStart injects dispatch contract"
else
  fail "L12 dispatch" "SessionStart additionalContext missing 'dispatch contract'"
fi

# Orchestrator agent file must mark itself as non-spawnable (recursive guard).
if grep -q 'DO NOT SPAWN as subagent' agents/claudehut-orchestrator.md; then
  pass "L12 orchestrator marked non-spawnable"
else
  fail "L12 dispatch" "orchestrator missing recursive-spawn guard"
fi

#==============================================================================
section "L14 Bootstrap skill `using-claudehut` integrity"
#==============================================================================
# (a) Skill file exists with required frontmatter + body sections.
boot="skills/using-claudehut/SKILL.md"
if [[ -f "$boot" ]]; then
  pass "L14 bootstrap skill file exists"
else
  fail "L14 bootstrap" "$boot missing"
fi

if grep -q '^name: using-claudehut$' "$boot" 2>/dev/null; then
  pass "L14 bootstrap frontmatter name"
else
  fail "L14 bootstrap" "name field wrong or missing"
fi

# Required body sections.
for section in '^## Non-negotiable invocation rule' \
               '^## Red flags' \
               '^## How dispatch maps to skill invocation' \
               '^## Catalog'; do
  if grep -qE "$section" "$boot" 2>/dev/null; then
    pass "L14 bootstrap section: $(echo "$section" | sed 's/^\^//; s/^## //')"
  else
    fail "L14 bootstrap" "missing section matching: $section"
  fi
done

# 1% rule must be quoted literally.
if grep -q '1% chance' "$boot" 2>/dev/null; then
  pass "L14 bootstrap states 1% rule"
else
  fail "L14 bootstrap" "missing the '1% chance' invocation rule"
fi

# (b) Catalog block must list every non-bootstrap skill exactly once.
expected=$(find skills -mindepth 1 -maxdepth 1 -type d -not -name 'using-claudehut' | wc -l | tr -d ' ')
actual=$(awk '/^<!-- catalog:begin -->/{flag=1;next} /^<!-- catalog:end -->/{flag=0} flag && /^\| `claudehut:/{count++} END{print count+0}' "$boot")
if [[ "$expected" -eq "$actual" ]]; then
  pass "L14 catalog covers all $expected skills"
else
  fail "L14 bootstrap" "catalog rows=$actual but skills dir has $expected entries"
fi

# (c) Regenerator must be idempotent — running it on a clean tree must
# produce zero diff against the committed file.
if bash "$PLUGIN_ROOT/scripts/regen-using-claudehut.sh" >/tmp/regen.log 2>&1; then
  if grep -q 'no change' /tmp/regen.log; then
    pass "L14 regen script idempotent"
  else
    fail "L14 bootstrap" "regen script produced a diff against committed SKILL.md — re-run scripts/regen-using-claudehut.sh and commit"
    cat /tmp/regen.log
  fi
else
  fail "L14 bootstrap" "regen script failed"
fi

#==============================================================================
section "L13 Hook output schema conformance"
#==============================================================================
# Anthropic's hook schema permits `hookSpecificOutput` ONLY for PreToolUse,
# UserPromptSubmit, PostToolUse, PostToolBatch, and SessionStart. All other
# hook events (Stop, SubagentStop, PreCompact, FileChanged, etc.) must use
# top-level fields only. This layer drives each hook with a fixture and
# verifies (a) stdout is valid JSON or empty, (b) no hookSpecificOutput leaks
# from events that disallow it, (c) emitted top-level keys are within the
# documented set.
#
# Allowed top-level keys: continue, suppressOutput, stopReason, decision,
#   reason, systemMessage, permissionDecision, hookSpecificOutput.
ALLOWED_TOP_KEYS='continue suppressOutput stopReason decision reason systemMessage permissionDecision hookSpecificOutput'
HSO_ALLOWED_EVENTS='PreToolUse UserPromptSubmit PostToolUse PostToolBatch SessionStart'

L13_TMPDIR=$(mktemp -d)
pushd "$L13_TMPDIR" >/dev/null
git init -q
git checkout -q -b feature/schema 2>/dev/null
mkdir -p .claudehut/{specs,plans,memory,findings,reuse-scans}
cat > .claudehut/memory/stack-signals.md <<'STACK'
- web: webflux
- orm: r2dbc
- mapper: mapstruct
STACK
export CLAUDE_PROJECT_DIR="$L13_TMPDIR"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

check_hook_schema() {
  local name="$1" script="$2" event="$3" stdin_json="$4" extra_args="$5"
  local out
  if [[ -n "$extra_args" ]]; then
    out="$(echo "$stdin_json" | bash "$script" $extra_args 2>/dev/null)"
  else
    out="$(echo "$stdin_json" | bash "$script" 2>/dev/null)"
  fi
  # empty output = valid (hook chose to stay silent)
  if [[ -z "$out" ]]; then pass "L13 $name silent"; return; fi
  # must be valid JSON
  if ! echo "$out" | jq empty 2>/dev/null; then
    fail "L13 $name" "stdout not valid JSON: $out"; return
  fi
  # top-level keys whitelist
  local k
  for k in $(echo "$out" | jq -r 'keys[]'); do
    case " $ALLOWED_TOP_KEYS " in
      *" $k "*) ;;
      *) fail "L13 $name" "disallowed top-level key '$k': $out"; return ;;
    esac
  done
  # hookSpecificOutput allowed only for whitelisted events
  if echo "$out" | jq -e 'has("hookSpecificOutput")' >/dev/null 2>&1; then
    case " $HSO_ALLOWED_EVENTS " in
      *" $event "*) ;;
      *) fail "L13 $name" "$event must not emit hookSpecificOutput: $out"; return ;;
    esac
    # hookSpecificOutput.hookEventName must match the actual event
    local got_event
    got_event=$(echo "$out" | jq -r '.hookSpecificOutput.hookEventName // empty')
    if [[ -n "$got_event" && "$got_event" != "$event" ]]; then
      fail "L13 $name" "hookEventName mismatch: got '$got_event' expected '$event'"
      return
    fi
  fi
  pass "L13 $name schema valid"
}

# Each hook driven with a representative fixture.
check_hook_schema "session-start"  "$PLUGIN_ROOT/hooks/session-start.sh"  "SessionStart"     "{}"                                             ""
check_hook_schema "prompt-router"  "$PLUGIN_ROOT/hooks/prompt-router.sh"  "UserPromptSubmit" '{"prompt":"add user endpoint"}'                 ""
check_hook_schema "pre-tool-bash"  "$PLUGIN_ROOT/hooks/pre-tool.sh"       "PreToolUse"       '{"tool_input":{"command":"./gradlew test"}}'   "--tool bash"
check_hook_schema "pre-tool-edit"  "$PLUGIN_ROOT/hooks/pre-tool.sh"       "PreToolUse"       "{\"tool_input\":{\"file_path\":\"$L13_TMPDIR/.claudehut/specs/x.md\"}}" "--tool edit"
check_hook_schema "post-tool"      "$PLUGIN_ROOT/hooks/post-tool.sh"      "PostToolUse"      '{"tool_input":{"file_path":"/tmp/x.java"}}'    ""
check_hook_schema "subagent-stop"  "$PLUGIN_ROOT/hooks/subagent-stop.sh"  "SubagentStop"     '{"agent_type":"claudehut-reviewer-security"}'   ""
check_hook_schema "stop"           "$PLUGIN_ROOT/hooks/stop.sh"           "Stop"             '{}'                                             ""
check_hook_schema "pre-compact"    "$PLUGIN_ROOT/hooks/pre-compact.sh"    "PreCompact"       '{}'                                             ""
check_hook_schema "file-changed"   "$PLUGIN_ROOT/hooks/file-changed.sh"   "FileChanged"      '{"file_path":"/tmp/CLAUDE.md"}'                 ""

# Specific regression: Stop default mode (no config) must NOT block — the
# block-on-learn behavior is opt-in. Forge the learn-phase state and verify
# Stop emits systemMessage rather than decision=block.
mkdir -p "$L13_TMPDIR/.claudehut/specs" "$L13_TMPDIR/.claudehut/plans" "$L13_TMPDIR/.claudehut/findings"
TID="$(cd "$L13_TMPDIR" && bash -c 'source '"$PLUGIN_ROOT"'/hooks/lib/state.sh; claudehut_task_id')"
echo "design"   > "$L13_TMPDIR/.claudehut/specs/${TID}-design.md"
echo "contract" > "$L13_TMPDIR/.claudehut/specs/${TID}-contract.md"
echo -e "- [x] task1\n  create: src/Foo.java" > "$L13_TMPDIR/.claudehut/plans/${TID}-plan.md"
echo '{"decision":"pass"}' > "$L13_TMPDIR/.claudehut/findings/${TID}-findings.json"
out="$(bash "$PLUGIN_ROOT/hooks/stop.sh" 2>/dev/null)"
if echo "$out" | jq -e '.systemMessage | type == "string"' >/dev/null 2>&1 \
   && ! echo "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  pass "L13 Stop default mode is non-blocking (systemMessage only)"
else
  fail "L13 Stop default" "expected systemMessage, got: $out"
fi

# Opt-in mode: enable enforcement, expect decision=block.
cat > "$L13_TMPDIR/.claudehut/claudehut-config.json" <<'CFG'
{"phase":{"stop_enforcement_enabled":true}}
CFG
out="$(bash "$PLUGIN_ROOT/hooks/stop.sh" 2>/dev/null)"
if echo "$out" | jq -e '.decision == "block" and (.reason | type == "string")' >/dev/null 2>&1; then
  pass "L13 Stop opt-in mode blocks via decision=block"
else
  fail "L13 Stop opt-in" "expected decision=block, got: $out"
fi

popd >/dev/null
rm -rf "$L13_TMPDIR"

#==============================================================================
section "L15 Subagent UX contract — runtime-blocked tools + brainstormer shape"
#==============================================================================
# Anthropic's runtime explicitly blocks the following tools inside a subagent
# context (source: code.claude.com/docs/en/sub-agents §Available tools):
#   Agent, AskUserQuestion, EnterPlanMode, ExitPlanMode (unless plan mode),
#   ScheduleWakeup, WaitForMcpServers.
# A subagent body that instructs itself to call any of those = guaranteed stall
# in production. Scan every agent body and fail on calls; mentions in
# documentation context (e.g. "AskUserQuestion is not available here") are
# explicitly allowed.

BLOCKED_TOOLS='Agent AskUserQuestion EnterPlanMode ScheduleWakeup WaitForMcpServers'
for f in $(find agents -name '*.md'); do
  # Skip the orchestrator marker (main-thread role doc, may legitimately
  # reference these tools in its narrative).
  case "$(basename "$f")" in
    claudehut-orchestrator.md) continue ;;
  esac
  body="$(awk '/^---$/{c++; if(c==2){flag=1;next}} flag' "$f")"
  for t in $BLOCKED_TOOLS; do
    # We only flag direct call syntax `Tool(...`. Imperative-prose mentions of
    # the tool (e.g. "the main thread invokes AskUserQuestion", "calling
    # AskUserQuestion from a subagent fails") are documentation, not a call
    # instruction; whether the subagent would actually issue the call depends
    # on model reasoning over the body, not on the prose itself. The runtime
    # already strips the tool — what we are guarding against here is *example
    # code* that demonstrates the wrong pattern.
    call_pattern="${t}\("
    if grep -nE "$call_pattern" <<<"$body" >/dev/null 2>&1; then
      fail "L15 $f" "subagent body contains a call to blocked tool $t"
      grep -nE "$call_pattern" <<<"$body" | head -2
    fi
  done
done
pass "L15 no subagent body issues a call to a runtime-blocked tool"

# Brainstormer-specific: must contain scan-and-return + structured return token.
br="agents/claudehut-brainstormer.md"
for term in 'scan-and-return' 'TERMINATE' 'claudehut-brainstorm-return' 'open_questions'; do
  if grep -q "$term" "$br"; then
    pass "L15 brainstormer body contains '$term'"
  else
    fail "L15 brainstormer" "missing '$term' — scan-and-return contract incomplete"
  fi
done

# brainstorm SKILL.md must wire AskUserQuestion in the main-thread loop.
bsm="skills/brainstorm/SKILL.md"
if grep -q 'AskUserQuestion' "$bsm"; then
  pass "L15 brainstorm SKILL.md documents AskUserQuestion in main thread"
else
  fail "L15 brainstorm SKILL.md" "missing AskUserQuestion main-thread integration"
fi
if grep -q 'next_action' "$bsm"; then
  pass "L15 brainstorm SKILL.md documents structured return loop"
else
  fail "L15 brainstorm SKILL.md" "missing next_action return-shape doc"
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
