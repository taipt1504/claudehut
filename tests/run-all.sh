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

mkdir -p .claudehut/{specs,plans,memory,findings,reuse-scans,state}

# Test: route phase — a FRESH task (no route.json, no design doc) triages first (Phase 3).
phase=$(claudehut_phase)
[[ "$phase" == "route" ]] && pass "phase=route when fresh (Phase 3 triage-first)" || fail "state.sh" "expected route got '$phase'"

# Create design doc with NO route.json → legacy fallthrough (pre-routing task) → spec
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
section "L2.1b bin/claudehut-state runs (was sourcing a nonexistent lib path)"
#==============================================================================
# The CLI sourced scripts/hooks/lib/state.sh (wrong) and exited 1 on every call,
# silently breaking every `claudehut-state ...` agent-prose invocation. Run it for real.
BIN="$PLUGIN_ROOT/bin/claudehut-state"
BTMP=$(mktemp -d)
( cd "$BTMP" && git init -q && git checkout -q -b feature/bin-test 2>/dev/null )
mkdir -p "$BTMP/.claudehut/memory"
printf -- '- web: webflux\n- orm: r2dbc\n' > "$BTMP/.claudehut/memory/stack-signals.md"
printf '{"phase":{"loop_max_retries":5}}\n' > "$BTMP/.claudehut/claudehut-config.json"
if CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" CLAUDE_PROJECT_DIR="$BTMP" bash "$BIN" help >/dev/null 2>&1; then
  pass "L2.1b claudehut-state runs (lib path resolves)"
else
  fail "L2.1b claudehut-state" "bin exits non-zero — lib path broken"
fi
out=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" CLAUDE_PROJECT_DIR="$BTMP" bash "$BIN" stack web 2>/dev/null)
[[ "$out" == "webflux" ]] && pass "L2.1b stack web → webflux (no dot-prefix bug)" || fail "L2.1b stack" "expected webflux, got '$out'"
out=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" CLAUDE_PROJECT_DIR="$BTMP" bash "$BIN" config phase.loop_max_retries 2>/dev/null)
[[ "$out" == "5" ]] && pass "L2.1b config phase.loop_max_retries → 5 (wires 1.4)" || fail "L2.1b config" "expected 5, got '$out'"
rm -rf "$BTMP"; unset out BIN BTMP

# Regression guard for the bin-broken class: no bin may source the nonexistent
# scripts/hooks/lib/ path (claudehut-state/finish/rollback all had this; it exits 1).
if grep -rl 'scripts/hooks/lib/state.sh' "$PLUGIN_ROOT/bin/" >/dev/null 2>&1; then
  fail "L2.1b bin lib path" "a bin sources the wrong scripts/hooks/lib/state.sh: $(grep -rl 'scripts/hooks/lib/state.sh' "$PLUGIN_ROOT/bin/")"
else
  pass "L2.1b no bin sources the wrong lib path"
fi

# state.sh helpers used by bins/discover/scope-check must be defined.
for fn in claudehut_active_task claudehut_state_dir; do
  if grep -q "^$fn()" "$PLUGIN_ROOT/hooks/lib/state.sh"; then
    pass "L2.1b state.sh defines $fn"
  else
    fail "L2.1b state.sh" "$fn undefined — callers (finish/rollback/discover/scope-check) crash"
  fi
done

# 1.7 end-to-end: claudehut-finish removes the active-task pointer (phase=learn,
# clean tree, confirmed). Validates the pointer is cleanable, not just written.
FTMP=$(mktemp -d)
(
  cd "$FTMP" && git init -q && git config user.email t@t && git config user.name t && git checkout -q -b feature/fin 2>/dev/null
  mkdir -p .claudehut/{specs,plans,memory,findings,state}
)
FTID="$(bash -c "source $PLUGIN_ROOT/hooks/lib/state.sh; CLAUDE_PROJECT_DIR='$FTMP' claudehut_task_id")"
echo design > "$FTMP/.claudehut/specs/${FTID}-design.md"
echo contract > "$FTMP/.claudehut/specs/${FTID}-contract.md"
printf -- '- [x] done\n' > "$FTMP/.claudehut/plans/${FTID}-plan.md"
echo '{"decision":"pass"}' > "$FTMP/.claudehut/findings/${FTID}-findings.json"
printf '{"task_id":"%s"}\n' "$FTID" > "$FTMP/.claudehut/state/active-task.json"
( cd "$FTMP" && git add -A && git commit -qm seed )   # clean tree for finish's git-diff check
echo "yes" | CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" CLAUDE_PROJECT_DIR="$FTMP" bash "$PLUGIN_ROOT/bin/claudehut-finish" >/dev/null 2>&1
if [[ ! -f "$FTMP/.claudehut/state/active-task.json" ]]; then
  pass "L2.1b claudehut-finish removes active-task pointer (1.7 cleanup works)"
else
  fail "L2.1b finish" "active-task.json not removed — finish aborted before cleanup"
fi
rm -rf "$FTMP"; unset FTMP FTID fn

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

# L2.5b — parallel group scan
script3="$PLUGIN_ROOT/skills/plan/scripts/plan-parallel-group-scan.sh"
tmp=$(mktemp -t test-pg.XXXXXX)

# Good: 2 independent tasks in group 1, 1 dependent in group 2
cat > "$tmp" <<'P'
# Plan
## Task 1: create Foo
**Files:**
- create: `src/main/java/Foo.java`
- test:   `src/test/java/FooTest.java`
**Depends on:** (none)
**Parallel group:** 1
- [ ] complete
---
## Task 2: create Bar
**Files:**
- create: `src/main/java/Bar.java`
- test:   `src/test/java/BarTest.java`
**Depends on:** (none)
**Parallel group:** 1
- [ ] complete
---
## Task 3: create FooBar
**Files:**
- create: `src/main/java/FooBar.java`
- test:   `src/test/java/FooBarTest.java`
**Depends on:** Task 1, Task 2
**Parallel group:** 2
- [ ] complete
P
bash "$script3" "$tmp" >/dev/null 2>&1 && pass "L2.5b parallel-group scan: valid plan accepted" || fail "plan-pg-scan" "rejected valid parallel groups"

# Bad: file conflict within same group
cat > "$tmp" <<'P'
# Plan
## Task 1: create Foo
**Files:**
- create: `src/main/java/Shared.java`
**Depends on:** (none)
**Parallel group:** 1
- [ ] complete
---
## Task 2: also touch Shared
**Files:**
- modify: `src/main/java/Shared.java`
**Depends on:** (none)
**Parallel group:** 1
- [ ] complete
P
if bash "$script3" "$tmp" >/dev/null 2>&1; then fail "plan-pg-scan" "accepted file conflict in same group"; else pass "L2.5b parallel-group scan: rejects file conflict in group"; fi

# Bad: dep in same group
cat > "$tmp" <<'P'
# Plan
## Task 1: base
**Files:**
- create: `src/main/java/Base.java`
**Depends on:** (none)
**Parallel group:** 1
- [ ] complete
---
## Task 2: depends on task 1 but same group
**Files:**
- create: `src/main/java/Ext.java`
**Depends on:** Task 1
**Parallel group:** 1
- [ ] complete
P
if bash "$script3" "$tmp" >/dev/null 2>&1; then fail "plan-pg-scan" "accepted dep with same group"; else pass "L2.5b parallel-group scan: rejects dep in same group"; fi

# Bad: missing Parallel group field
cat > "$tmp" <<'P'
# Plan
## Task 1: no group
**Files:**
- create: `src/main/java/Foo.java`
**Depends on:** (none)
- [ ] complete
P
if bash "$script3" "$tmp" >/dev/null 2>&1; then fail "plan-pg-scan" "accepted task missing Parallel group"; else pass "L2.5b parallel-group scan: rejects missing Parallel group field"; fi

rm "$tmp"

#==============================================================================
section "L2.8 regenerate-recent.sh"
#==============================================================================
script="$PLUGIN_ROOT/skills/learn/scripts/regenerate-recent.sh"
rr_tmp=$(mktemp -d)
mkdir -p "$rr_tmp/.claudehut/memory"

# Case 1: absent learnings.jsonl → stub
CLAUDE_PROJECT_DIR="$rr_tmp" bash "$script" >/dev/null 2>&1
if grep -q '(none yet' "$rr_tmp/.claudehut/memory/learnings-recent.md" 2>/dev/null; then
  pass "L2.8 regenerate-recent: absent JSONL → stub"
else fail "L2.8 regenerate-recent" "absent JSONL did not produce stub"; fi

# Case 2: empty learnings.jsonl → stub
: > "$rr_tmp/.claudehut/memory/learnings.jsonl"
CLAUDE_PROJECT_DIR="$rr_tmp" bash "$script" >/dev/null 2>&1
if grep -q '(none yet' "$rr_tmp/.claudehut/memory/learnings-recent.md" 2>/dev/null; then
  pass "L2.8 regenerate-recent: empty JSONL → stub"
else fail "L2.8 regenerate-recent" "empty JSONL did not produce stub"; fi

# Case 3: one entry → task_id present, stub gone
echo '{"task_id":"feat-xyz-001","category":"pattern","title":"Use jq -s slurp","tags":["jq","bash"],"ts":"2026-05-29T10:00:00Z"}' \
  >> "$rr_tmp/.claudehut/memory/learnings.jsonl"
CLAUDE_PROJECT_DIR="$rr_tmp" bash "$script" >/dev/null 2>&1
if grep -q 'feat-xyz-001' "$rr_tmp/.claudehut/memory/learnings-recent.md" 2>/dev/null; then
  pass "L2.8 regenerate-recent: entry → task_id present"
else fail "L2.8 regenerate-recent" "entry not found in learnings-recent.md"; fi
if ! grep -q '(none yet' "$rr_tmp/.claudehut/memory/learnings-recent.md" 2>/dev/null; then
  pass "L2.8 regenerate-recent: stub absent after real entry"
else fail "L2.8 regenerate-recent" "stub still present after real entry"; fi

# Case 4: N cap (25 entries, default 20)
for i in $(seq 1 24); do
  printf '{"task_id":"task-%02d","category":"pattern","title":"entry %d","ts":"2026-05-29T10:%02d:00Z"}\n' \
    "$i" "$i" "$i" >> "$rr_tmp/.claudehut/memory/learnings.jsonl"
done
CLAUDE_PROJECT_DIR="$rr_tmp" bash "$script" >/dev/null 2>&1
bullet_count=$(grep -c '^- \*\*' "$rr_tmp/.claudehut/memory/learnings-recent.md" 2>/dev/null || echo 0)
if [[ "$bullet_count" -eq 20 ]]; then
  pass "L2.8 regenerate-recent: N=20 cap respected (25 entries → 20 bullets)"
else fail "L2.8 regenerate-recent" "expected 20 bullets, got $bullet_count"; fi

# Case 5: explicit N=5
CLAUDE_PROJECT_DIR="$rr_tmp" bash "$script" 5 >/dev/null 2>&1
bullet_count5=$(grep -c '^- \*\*' "$rr_tmp/.claudehut/memory/learnings-recent.md" 2>/dev/null || echo 0)
if [[ "$bullet_count5" -eq 5 ]]; then
  pass "L2.8 regenerate-recent: explicit N=5 respected"
else fail "L2.8 regenerate-recent" "expected 5 bullets with N=5, got $bullet_count5"; fi

rm -rf "$rr_tmp"; unset rr_tmp bullet_count bullet_count5

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

if jq -e '.hookSpecificOutput.additionalContext | contains("Phase:    route")' "$TMPDIR/out.json" >/dev/null 2>&1; then
  pass "SessionStart: derives phase=route (fresh task triages first)"
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
section "L3.2b Hook: SessionStart active-task pointer + rename/orphan warning (1.7)"
#==============================================================================
PTMP=$(mktemp -d)
cd "$PTMP"
git init -q; git checkout -q -b feature/orig-task 2>/dev/null
mkdir -p .claudehut/{specs,plans,memory}
TID_ORIG="$(bash -c "source $PLUGIN_ROOT/hooks/lib/state.sh; CLAUDE_PROJECT_DIR='$PTMP' claudehut_task_id")"
echo "design" > ".claudehut/specs/${TID_ORIG}-design.md"
export CLAUDE_PROJECT_DIR="$PTMP"
# First session on the original branch → pointer written, no warning.
echo '{}' | bash "$PLUGIN_ROOT/hooks/session-start.sh" > "$PTMP/o1.json" 2>&1
if [[ -f "$PTMP/.claudehut/state/active-task.json" ]] && \
   [[ "$(jq -r '.task_id' "$PTMP/.claudehut/state/active-task.json")" == "$TID_ORIG" ]]; then
  pass "L3.2b active-task pointer written"
else
  fail "L3.2b pointer" "pointer not written or wrong task_id"
fi
if jq -e '.hookSpecificOutput.additionalContext | test("previous active task")' "$PTMP/o1.json" >/dev/null 2>&1; then
  fail "L3.2b" "false task-change note on first session"
else
  pass "L3.2b no task-change note on first session"
fi
# Task change: a pointer cannot tell a RENAME from a SWITCH, so the note must be
# neutral (state the fact, prescribe nothing) — and must NEVER falsely accuse of
# orphaning. Same neutral note in both cases below.
git branch -m feature/renamed-task 2>/dev/null
echo '{}' | bash "$PLUGIN_ROOT/hooks/session-start.sh" > "$PTMP/o2.json" 2>&1
if jq -e '.hookSpecificOutput.additionalContext | test("previous active task")' "$PTMP/o2.json" >/dev/null 2>&1; then
  pass "L3.2b task change → neutral note surfaced"
else
  fail "L3.2b note" "expected neutral task-change note: $(jq -r '.hookSpecificOutput.additionalContext' "$PTMP/o2.json" 2>/dev/null | head -3)"
fi
if jq -e '.hookSpecificOutput.additionalContext | test("ORPHANED")' "$PTMP/o2.json" >/dev/null 2>&1; then
  fail "L3.2b note" "must NOT accuse of orphaning (can't distinguish rename from switch)"
else
  pass "L3.2b note is non-accusatory (no false ORPHANED)"
fi
# Discriminating: a legitimate SWITCH to a separate new task must NOT be accused
# of orphaning either (this is the common multi-task flow the old wording broke).
git checkout -q -b feature/separate-task 2>/dev/null
echo '{}' | bash "$PLUGIN_ROOT/hooks/session-start.sh" > "$PTMP/o3.json" 2>&1
if jq -e '.hookSpecificOutput.additionalContext | test("ORPHANED")' "$PTMP/o3.json" >/dev/null 2>&1; then
  fail "L3.2b switch" "legitimate branch switch wrongly accused of orphaning"
else
  pass "L3.2b switch → no false orphan accusation (common multi-task flow safe)"
fi
cd "$PLUGIN_ROOT"
rm -rf "$PTMP"
unset CLAUDE_PROJECT_DIR TID_ORIG

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

# Fresh task → phase=route (pre-build); edit src/ → should deny (only build allows)
echo "{\"tool_input\":{\"file_path\":\"$TMPDIR/src/main/java/com/x/Foo.java\"}}" | bash "$PLUGIN_ROOT/hooks/pre-tool.sh" --tool edit > "$TMPDIR/out.json" 2>&1
if jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$TMPDIR/out.json" >/dev/null 2>&1; then
  pass "pre-tool: blocks src/ edit in non-build phase (route)"
else
  fail "pre-tool" "should block src/ outside build: $(cat $TMPDIR/out.json)"
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
section "L3.6 Hook: pre-tool migration safety gate (deterministic, write-time)"
#==============================================================================
MTMP=$(mktemp -d)
cd "$MTMP"
git init -q; git checkout -q -b feature/mig 2>/dev/null
mkdir -p .claudehut/{specs,plans,memory} src/main/resources/db/migration
export CLAUDE_PROJECT_DIR="$MTMP"

# Unsafe: ADD COLUMN NOT NULL without DEFAULT (validate-migration exit 1) → deny
# by the MIGRATION GATE specifically (it runs before the phase gate, so this is
# phase-independent). Assert both deny AND the migration-gate reason.
echo "{\"tool_input\":{\"file_path\":\"$MTMP/src/main/resources/db/migration/V1__add_col.sql\",\"content\":\"ALTER TABLE users ADD COLUMN tenant_id UUID NOT NULL;\"}}" \
  | bash "$PLUGIN_ROOT/hooks/pre-tool.sh" --tool edit > "$MTMP/out.json" 2>&1
if jq -e '.hookSpecificOutput.permissionDecision == "deny" and (.hookSpecificOutput.permissionDecisionReason | test("migration gate"))' "$MTMP/out.json" >/dev/null 2>&1; then
  pass "pre-tool: migration gate denies unsafe DDL (ADD COLUMN NOT NULL no DEFAULT)"
else
  fail "pre-tool migration" "should deny via migration gate: $(cat "$MTMP/out.json")"
fi

# Safe: CREATE TABLE → migration gate must NOT deny (a phase gate may deny for
# other reasons in this brainstorm fixture; we assert only that the MIGRATION GATE
# did not fire — phase-independent).
echo "{\"tool_input\":{\"file_path\":\"$MTMP/src/main/resources/db/migration/V2__create.sql\",\"content\":\"CREATE TABLE orders (id UUID PRIMARY KEY);\"}}" \
  | bash "$PLUGIN_ROOT/hooks/pre-tool.sh" --tool edit > "$MTMP/out.json" 2>&1
if jq -e '(.hookSpecificOutput.permissionDecisionReason // "") | test("migration gate")' "$MTMP/out.json" >/dev/null 2>&1; then
  fail "pre-tool migration" "false-positive migration-gate deny on safe CREATE TABLE: $(cat "$MTMP/out.json")"
else
  pass "pre-tool: migration gate allows safe DDL (CREATE TABLE)"
fi

# 1.3 Edit-path closure: an Edit that INTRODUCES unsafe DDL (new_string, no
# .content) must also be denied (file isn't written yet; validate new_string).
echo "{\"tool_input\":{\"file_path\":\"$MTMP/src/main/resources/db/migration/V3__alter.sql\",\"new_string\":\"ALTER TABLE users ADD COLUMN flag BOOLEAN NOT NULL;\"}}" \
  | bash "$PLUGIN_ROOT/hooks/pre-tool.sh" --tool edit > "$MTMP/out.json" 2>&1
if jq -e '.hookSpecificOutput.permissionDecision == "deny" and (.hookSpecificOutput.permissionDecisionReason | test("migration gate"))' "$MTMP/out.json" >/dev/null 2>&1; then
  pass "pre-tool: migration gate denies unsafe DDL via Edit new_string (1.3 closure)"
else
  fail "pre-tool migration edit" "Edit introducing unsafe DDL not denied: $(cat "$MTMP/out.json")"
fi

cd "$PLUGIN_ROOT"
rm -rf "$MTMP"
unset CLAUDE_PROJECT_DIR

#==============================================================================
section "L3.7 Hook: prompt-router surfaces loop retry cap (1.4 deterministic)"
#==============================================================================
RTMP=$(mktemp -d)
(
  cd "$RTMP" && git init -q && git config user.email t@t && git config user.name t && git checkout -q -b feature/loopcap 2>/dev/null
  mkdir -p .claudehut/{specs,plans,memory,findings}
)
RTID="$(bash -c "source $PLUGIN_ROOT/hooks/lib/state.sh; CLAUDE_PROJECT_DIR='$RTMP' claudehut_task_id")"
echo design > "$RTMP/.claudehut/specs/${RTID}-design.md"
echo contract > "$RTMP/.claudehut/specs/${RTID}-contract.md"
printf -- '- [x] complete\n' > "$RTMP/.claudehut/plans/${RTID}-plan.md"   # plan done, no findings → phase=loop
printf '{"phase":{"loop_max_retries":1}}\n' > "$RTMP/.claudehut/claudehut-config.json"
( cd "$RTMP" && git add -A && git commit -qm seed && git commit -q --allow-empty -m "refactor(loop): attempt 1" )  # retries=1 >= max=1
out="$(echo '{"prompt":"continue"}' | CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" CLAUDE_PROJECT_DIR="$RTMP" bash "$PLUGIN_ROOT/hooks/prompt-router.sh" 2>/dev/null)"
if echo "$out" | jq -e '.hookSpecificOutput.additionalContext | test("RETRY CAP REACHED")' >/dev/null 2>&1; then
  pass "L3.7 prompt-router surfaces RETRY CAP REACHED at retries>=loop_max_retries"
else
  fail "L3.7 loop cap" "expected cap surfacing, got: $(echo "$out" | jq -r '.hookSpecificOutput.additionalContext // .' 2>/dev/null | head -2)"
fi
rm -rf "$RTMP"; unset RTMP RTID out

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
[[ "$n_skills" -eq 31 ]] && pass "skill count: 31 (30 workflow/domain + using-claudehut bootstrap; +1 route)" || fail "coverage" "skill count: $n_skills (expected 31)"

# Hook events configured
n_hooks=$(jq -r '.hooks | keys[]' hooks/hooks.json | wc -l | tr -d ' ')
[[ "$n_hooks" -ge 7 ]] && pass "hook events: $n_hooks configured" || fail "hooks" "only $n_hooks events configured"

# MCP servers
n_mcp=$(jq -r '.mcpServers | keys[]' .mcp.json | wc -l | tr -d ' ')
[[ "$n_mcp" -ge 3 ]] && pass "MCP servers: $n_mcp configured" || fail "mcp" "only $n_mcp servers"
# 4.2: the memory MCP file path MUST reference the project dir (not a bare/relative
# path that resolves under the npx dist dir → ENOENT). Plugin .mcp.json substitutes
# ${CLAUDE_PROJECT_DIR}; the :-. default keeps it safe if copied to a project/user
# config. Guard against regressing to a bare path (the in-session ENOENT bug).
_mempath="$(jq -r '.mcpServers.memory.env.MEMORY_FILE_PATH // ""' .mcp.json)"
case "$_mempath" in
  '${CLAUDE_PROJECT_DIR'*'/.claudehut/memory/'*) pass "memory MCP path anchored to \${CLAUDE_PROJECT_DIR} (.claudehut/memory/)" ;;
  *) fail "mcp memory path" "MEMORY_FILE_PATH must start with \${CLAUDE_PROJECT_DIR...}: '$_mempath'" ;;
esac
unset _mempath

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

# Plan template must include Parallel group field
tmpl="$PLUGIN_ROOT/skills/plan/assets/templates/plan-doc.md.tmpl"
if grep -q 'Parallel group:' "$tmpl"; then
  pass "L4 plan template contains Parallel group field"
else
  fail "L4 plan template" "missing 'Parallel group:' field"
fi

# Planner agent must document Parallel group in output contract
if grep -q 'Parallel group' "$PLUGIN_ROOT/agents/claudehut-planner.md"; then
  pass "L4 planner agent documents Parallel group"
else
  fail "L4 planner agent" "missing Parallel group assignment logic"
fi

# plan-parallel-group-scan.sh must exist and be executable
pg_script="$PLUGIN_ROOT/skills/plan/scripts/plan-parallel-group-scan.sh"
if [[ -x "$pg_script" ]]; then
  pass "L4 plan-parallel-group-scan.sh exists and is executable"
else
  fail "L4 plan scripts" "plan-parallel-group-scan.sh missing or not executable"
fi

# Builder agent must be single-task (no "PickTask" loop)
builder="$PLUGIN_ROOT/agents/claudehut-builder.md"
if grep -q 'claudehut-builder-result' "$builder"; then
  pass "L4 builder agent has claudehut-builder-result return contract"
else
  fail "L4 builder agent" "missing claudehut-builder-result return block"
fi
if grep -q 'worktree' "$PLUGIN_ROOT/skills/build/SKILL.md"; then
  pass "L4 build skill documents worktree isolation"
else
  fail "L4 build skill" "missing worktree in dispatch contract"
fi

# merge script must exist and be executable
merge_script="$PLUGIN_ROOT/skills/build/scripts/merge-parallel-group.sh"
if [[ -x "$merge_script" ]]; then
  pass "L4 merge-parallel-group.sh exists and is executable"
else
  fail "L4 build scripts" "merge-parallel-group.sh missing or not executable"
fi

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
  "brainstorm|claudehut:claudehut-brainstormer"
  "spec|claudehut:claudehut-spec-writer"
  "plan|claudehut:claudehut-planner"
  "build|claudehut:claudehut-builder"
  "verify-review|claudehut:claudehut-verifier"
  "learn|claudehut:claudehut-learner"
)
for entry in "${phases[@]}"; do
  skill="${entry%%|*}"
  agent="${entry##*|}"
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
out="$(echo '{}' | bash "$PLUGIN_ROOT/hooks/stop.sh" 2>/dev/null)"
if echo "$out" | jq -e '.systemMessage | type == "string"' >/dev/null 2>&1 \
   && ! echo "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  pass "L13 Stop default mode is non-blocking (systemMessage only)"
else
  fail "L13 Stop default" "expected systemMessage, got: $out"
fi

# Opt-in mode: enable enforcement, first stop (no stop_hook_active) → decision=block.
cat > "$L13_TMPDIR/.claudehut/claudehut-config.json" <<'CFG'
{"phase":{"stop_enforcement_enabled":true}}
CFG
out="$(echo '{}' | bash "$PLUGIN_ROOT/hooks/stop.sh" 2>/dev/null)"
if echo "$out" | jq -e '.decision == "block" and (.reason | type == "string")' >/dev/null 2>&1; then
  pass "L13 Stop opt-in mode blocks via decision=block"
else
  fail "L13 Stop opt-in" "expected decision=block, got: $out"
fi

# Bounded escape (1.1): enforcement on BUT stop_hook_active=true (we already blocked)
# → must NOT block again; downgrade to systemMessage so the platform stop-loop can't fire.
out="$(echo '{"stop_hook_active":true}' | bash "$PLUGIN_ROOT/hooks/stop.sh" 2>/dev/null)"
if echo "$out" | jq -e '.systemMessage | type == "string"' >/dev/null 2>&1 \
   && ! echo "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  pass "L13 Stop bounded escape: stop_hook_active → systemMessage, not block"
else
  fail "L13 Stop escape" "expected systemMessage on stop_hook_active, got: $out"
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

# Task was renamed Agent (v2.1.63) but both aliases are stripped in nested
# contexts; a subagent must never call OR declare either.
BLOCKED_TOOLS='Task Agent AskUserQuestion EnterPlanMode ScheduleWakeup WaitForMcpServers'
L15_body_fail=0
for f in $(find agents -name '*.md'); do
  # Skip the orchestrator marker (main-thread role doc, may legitimately
  # reference these tools in its narrative).
  case "$(basename "$f")" in
    claudehut-orchestrator.md) continue ;;
  esac
  body="$(awk '/^---$/{c++; if(c==2){flag=1;next}} flag' "$f")"
  for t in $BLOCKED_TOOLS; do
    # Flag direct call syntax `Tool(`. Lines describing how the MAIN THREAD
    # dispatches THIS agent (e.g. "The main thread invokes you via `Task(...")
    # are documentation, not imperative subagent instructions — exclude them.
    call_pattern="${t}\("
    matches="$(grep -nE "$call_pattern" <<<"$body" 2>/dev/null \
               | grep -vE 'main thread invokes.*via|dispatches you via|dispatched via|invoke[sd]? you via' \
               || true)"
    if [[ -n "$matches" ]]; then
      fail "L15 $f" "subagent body contains a call to blocked tool $t"
      echo "$matches" | head -2
      L15_body_fail=$((L15_body_fail+1))
    fi
  done
done
[[ "$L15_body_fail" -eq 0 ]] && pass "L15 no subagent body issues a call to a runtime-blocked tool"

# L15 gap-b: no non-orchestrator agent may DECLARE Task or Agent in its
# frontmatter tools: line. The runtime strips them (nested dispatch unsupported);
# declaring them is a latent hazard. Catches a verifier that lists Task.
for f in $(find agents -name '*.md'); do
  case "$(basename "$f")" in
    claudehut-orchestrator.md) continue ;;
  esac
  head -1 "$f" | grep -q '^---$' || continue
  fm_block="$(awk '/^---$/{c++; if(c==2)exit} c==1' "$f")"
  tools_line="$(awk -F: '/^tools:/{sub(/^tools:[[:space:]]*/,""); print; exit}' <<<"$fm_block")"
  [[ -z "$tools_line" ]] && continue
  for bad_tool in Task Agent; do
    if echo "$tools_line" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -qx "$bad_tool"; then
      fail "L15 frontmatter $f" "tools: lists '$bad_tool' — nested subagent dispatch unsupported; remove it"
    fi
  done
done
pass "L15 no non-orchestrator agent declares Task or Agent in frontmatter tools:"

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
section "L16 Parallel build workflow contracts"
#==============================================================================
# Verify the end-to-end contract for parallel build dispatch:
#   - Build skill instructs one Agent per task (not one Agent for all tasks)
#   - Dispatch script supports task-number argument
#   - Merge script handles colon-separated task:branch pairs
#   - Builder result block shape is consistent across skill and agent

build_skill="$PLUGIN_ROOT/skills/build/SKILL.md"
builder_agent="$PLUGIN_ROOT/agents/claudehut-builder.md"
dispatch_script="$PLUGIN_ROOT/skills/build/scripts/dispatch-prompt.sh"
merge_script="$PLUGIN_ROOT/skills/build/scripts/merge-parallel-group.sh"

# Build skill must document parallel-group loop
for term in 'Parallel group' 'merge-parallel-group.sh' 'worktree'; do
  if grep -q "$term" "$build_skill"; then
    pass "L16 build SKILL.md contains '$term'"
  else
    fail "L16 build SKILL.md" "missing '$term' — parallel contract incomplete"
  fi
done

# Dispatch script accepts task-number (second positional arg)
if grep -q 'TASK_NUM' "$dispatch_script"; then
  pass "L16 dispatch-prompt.sh accepts TASK_NUM argument"
else
  fail "L16 dispatch-prompt.sh" "missing TASK_NUM parameter — cannot do per-task dispatch"
fi

# Dispatch script emits single-task plan block when TASK_NUM set
if grep -q 'Plan.*Task.*only\|single.*task\|only the requested task' "$dispatch_script"; then
  pass "L16 dispatch-prompt.sh emits single task block when TASK_NUM set"
else
  fail "L16 dispatch-prompt.sh" "does not restrict plan output to single task block"
fi

# Merge script handles task:branch pairs
if grep -q 'cherry-pick\|cherry_pick' "$merge_script"; then
  pass "L16 merge-parallel-group.sh performs cherry-pick"
else
  fail "L16 merge-parallel-group.sh" "missing cherry-pick — branches not merged"
fi
if grep -q 'task_num.*branch\|branch.*task_num\|pair' "$merge_script"; then
  pass "L16 merge-parallel-group.sh parses task:branch pairs"
else
  fail "L16 merge-parallel-group.sh" "missing task:branch pair parsing"
fi

# Builder result shape: task + commit_sha + verify_status
for field in '"task"' '"commit_sha"' '"verify_status"' '"task_id"'; do
  if grep -q "$field" "$builder_agent"; then
    pass "L16 builder result block has field $field"
  else
    fail "L16 builder agent" "claudehut-builder-result missing field $field"
  fi
done

# Builder agent MUST NOT still contain "PickTask" loop behavior
if grep -q 'PickTask' "$builder_agent"; then
  fail "L16 builder agent" "still contains PickTask loop — must be single-task executor"
else
  pass "L16 builder agent: no PickTask loop (single-task executor)"
fi

# Build skill MUST NOT instruct single big builder for all tasks
if grep -q 'claudehut-builder.*all tasks\|loop.*all.*tasks\|each.*task.*loop' "$build_skill" 2>/dev/null; then
  fail "L16 build SKILL.md" "still contains single-builder-for-all-tasks pattern"
else
  pass "L16 build SKILL.md: no single-builder-all-tasks pattern"
fi

# Verify planner G5 gate references parallel-group-scan
planner="$PLUGIN_ROOT/agents/claudehut-planner.md"
if grep -q 'plan-parallel-group-scan.sh' "$planner"; then
  pass "L16 planner agent G5 gate wires plan-parallel-group-scan.sh"
else
  fail "L16 planner agent" "G5 gate missing plan-parallel-group-scan.sh reference"
fi

# run-parallel-group.sh must exist and be executable
rpg_script="$PLUGIN_ROOT/skills/build/scripts/run-parallel-group.sh"
if [[ -x "$rpg_script" ]]; then
  pass "L16 run-parallel-group.sh exists and is executable"
else
  fail "L16 build scripts" "run-parallel-group.sh missing or not executable"
fi

# run-parallel-group.sh must invoke claude (OS-level parallelism, Path B)
if grep -q 'claude' "$rpg_script" 2>/dev/null; then
  pass "L16 run-parallel-group.sh invokes claude (Path B dispatch)"
else
  fail "L16 run-parallel-group.sh" "missing 'claude' invocation — not a parallel dispatcher"
fi

# run-parallel-group.sh must create git worktrees (isolated execution)
if grep -q 'worktree add' "$rpg_script" 2>/dev/null; then
  pass "L16 run-parallel-group.sh uses git worktree add"
else
  fail "L16 run-parallel-group.sh" "missing 'worktree add' — no worktree isolation"
fi

# Build skill must reference run-parallel-group.sh
if grep -q 'run-parallel-group.sh' "$build_skill"; then
  pass "L16 build SKILL.md references run-parallel-group.sh"
else
  fail "L16 build SKILL.md" "missing run-parallel-group.sh reference"
fi

# CLAUDEHUT_TASK_ID env override must exist in state.sh (worktree builder fix)
state_sh="$PLUGIN_ROOT/hooks/lib/state.sh"
if grep -q 'CLAUDEHUT_TASK_ID' "$state_sh"; then
  pass "L16 state.sh has CLAUDEHUT_TASK_ID env override"
else
  fail "L16 state.sh" "missing CLAUDEHUT_TASK_ID override — worktree builders will derive wrong task id"
fi

# Bug-2 fix: worker must symlink .claudehut into worktree (hooks/state can read plan)
if grep -q 'ln -s.*\.claudehut' "$rpg_script"; then
  pass "L16 run-parallel-group.sh symlinks .claudehut into worktree"
else
  fail "L16 run-parallel-group.sh" "missing .claudehut symlink — scope-check hook + state break in worktree"
fi

# Bug-1 fix: worker persona injected via --append-system-prompt + pinned model
if grep -q 'append-system-prompt' "$rpg_script"; then
  pass "L16 run-parallel-group.sh injects guardrails via --append-system-prompt"
else
  fail "L16 run-parallel-group.sh" "missing --append-system-prompt — builder persona not loaded (frontmatter inert for --print)"
fi
if grep -q -- '--model' "$rpg_script"; then
  pass "L16 run-parallel-group.sh pins worker model (cost control)"
else
  fail "L16 run-parallel-group.sh" "missing --model — worker runs on session default"
fi

# Aggregation block (#13): per-task watchdog timeout
if grep -q 'TASK_TIMEOUT' "$rpg_script"; then
  pass "L16 run-parallel-group.sh has per-task timeout watchdog"
else
  fail "L16 run-parallel-group.sh" "missing TASK_TIMEOUT — a hung worker blocks the group"
fi

# Per-group integration gate (decision: per-group, not final-only)
if grep -q 'integration gate' "$rpg_script"; then
  pass "L16 run-parallel-group.sh runs per-group integration gate"
else
  fail "L16 run-parallel-group.sh" "missing per-group compile+test gate"
fi

# Stub-commit step (decision L2): scaffold-stubs.sh exists + executable + commits
stub_script="$PLUGIN_ROOT/skills/build/scripts/scaffold-stubs.sh"
if [[ -x "$stub_script" ]]; then
  pass "L16 scaffold-stubs.sh exists and is executable"
else
  fail "L16 build scripts" "scaffold-stubs.sh missing or not executable"
fi
if grep -q 'scaffold stubs for' "$stub_script"; then
  pass "L16 scaffold-stubs.sh commits stub scaffold"
else
  fail "L16 scaffold-stubs.sh" "missing stub commit step"
fi
if grep -q 'scaffold-stubs.sh' "$build_skill"; then
  pass "L16 build SKILL.md wires scaffold-stubs.sh (stub step before groups)"
else
  fail "L16 build SKILL.md" "missing scaffold-stubs.sh — stub step not in loop"
fi

# Planner must document parallelization-not-worth heuristic (#15)
if grep -qi 'not worth parallelizing\|< 3 tasks\|single-builder' "$planner"; then
  pass "L16 planner documents over-parallelization guard"
else
  fail "L16 planner agent" "missing over-parallelization heuristic (trivial/few-task tasks)"
fi

# ── Doc-research-driven hardening (item 1/2/3 definitive solutions) ──────────

# Item 1: workers load the real builder persona via --agent (proper TDD steering),
# not just a prompt fragment. Probe + plugin-namespace ref.
if grep -q -- '--agent' "$rpg_script" && grep -q 'claudehut:claudehut-builder' "$rpg_script"; then
  pass "L16 run-parallel-group.sh loads builder persona via --agent (plugin namespace)"
else
  fail "L16 run-parallel-group.sh" "missing --agent claudehut:claudehut-builder persona load"
fi
if grep -q 'claude agents list' "$rpg_script"; then
  pass "L16 run-parallel-group.sh probes agent resolvability (graceful fallback)"
else
  fail "L16 run-parallel-group.sh" "missing 'claude agents list' probe — --agent would hard-fail when unresolvable"
fi

# Item 3: --settings merge so plugin enablement (hooks) is found from out-of-tree cwd
if grep -q -- '--settings' "$rpg_script"; then
  pass "L16 run-parallel-group.sh merges project --settings (plugin enablement from /tmp cwd)"
else
  fail "L16 run-parallel-group.sh" "missing --settings merge — project-scope plugin hooks won't load in worktree"
fi
# bash 3.2-safe empty-array expansion guard
if grep -q 'AGENT_ARGS\[@\]+' "$rpg_script"; then
  pass "L16 run-parallel-group.sh uses bash-3.2-safe empty-array expansion"
else
  fail "L16 run-parallel-group.sh" "raw \${AGENT_ARGS[@]} aborts under set -u when empty (bash 3.2)"
fi
# symlink nesting guard
if grep -q '\[\[ -e "\$WT_PATH/.claudehut" \]\] ||' "$rpg_script"; then
  pass "L16 run-parallel-group.sh guards .claudehut symlink against nesting"
else
  fail "L16 run-parallel-group.sh" "ungated symlink nests inside a tracked .claudehut dir"
fi
# leak-proof worktree cleanup via EXIT trap
if grep -q 'trap cleanup EXIT' "$rpg_script"; then
  pass "L16 run-parallel-group.sh cleans worktrees via EXIT trap (no leak on error)"
else
  fail "L16 run-parallel-group.sh" "worktree cleanup not in EXIT trap — leaks on early/error exit"
fi

# Item 2: scaffold compile-fix retry loop via documented session resume
if grep -q 'session_id' "$stub_script" && grep -q -- '--resume' "$stub_script"; then
  pass "L16 scaffold-stubs.sh has compile-fix retry loop (--output-format json + --resume)"
else
  fail "L16 scaffold-stubs.sh" "missing resume-based compile-fix retry loop"
fi
# empty session_id guard (advisor #4)
if grep -q 'could not capture scaffold session_id' "$stub_script"; then
  pass "L16 scaffold-stubs.sh fails loudly on empty session_id"
else
  fail "L16 scaffold-stubs.sh" "no guard for empty session_id (--resume \"\" would misbehave)"
fi
# scaffold bypass exported + honored in the WIRED hook (pre-tool.sh, not dead script)
if grep -q 'CLAUDEHUT_SCAFFOLD=1' "$stub_script"; then
  pass "L16 scaffold-stubs.sh exports CLAUDEHUT_SCAFFOLD bypass"
else
  fail "L16 scaffold-stubs.sh" "missing CLAUDEHUT_SCAFFOLD — off-plan stub writes get scope-blocked"
fi
pre_tool="$PLUGIN_ROOT/hooks/pre-tool.sh"
if grep -q 'CLAUDEHUT_SCAFFOLD' "$pre_tool"; then
  pass "L16 pre-tool.sh (wired hook) honors CLAUDEHUT_SCAFFOLD bypass"
else
  fail "L16 pre-tool.sh" "scaffold bypass not in the WIRED PreToolUse hook"
fi

# gitignore-aware plan commit (don't abort when .claudehut is gitignored)
if grep -q 'check-ignore' "$merge_script"; then
  pass "L16 merge-parallel-group.sh respects gitignored .claudehut (no set -e abort)"
else
  fail "L16 merge-parallel-group.sh" "git add of gitignored plan aborts merge under set -e"
fi

# Worker-hang guard: a worker is a FULL session, so the whole hook stack fires.
# Block-capable ambient hooks (prompt-router, stop) must early-exit under
# CLAUDEHUT_WORKER, else a -p worker can never satisfy a block → hangs to watchdog.
pr_hook="$PLUGIN_ROOT/hooks/prompt-router.sh"
stop_hook="$PLUGIN_ROOT/hooks/stop.sh"
if grep -q 'CLAUDEHUT_WORKER' "$pr_hook"; then
  pass "L16 prompt-router.sh has CLAUDEHUT_WORKER bypass (no skip-phrase block on workers)"
else
  fail "L16 prompt-router.sh" "missing CLAUDEHUT_WORKER guard — user intent with skip-phrase hangs every worker"
fi
if grep -q 'CLAUDEHUT_WORKER' "$stop_hook"; then
  pass "L16 stop.sh has CLAUDEHUT_WORKER bypass (no Stop-block on workers)"
else
  fail "L16 stop.sh" "missing CLAUDEHUT_WORKER guard — Stop-block would hang headless workers"
fi
if grep -q 'CLAUDEHUT_WORKER=1' "$rpg_script"; then
  pass "L16 run-parallel-group.sh exports CLAUDEHUT_WORKER=1"
else
  fail "L16 run-parallel-group.sh" "workers not tagged CLAUDEHUT_WORKER — ambient hooks can block them"
fi
if grep -q 'CLAUDEHUT_WORKER=1' "$stub_script"; then
  pass "L16 scaffold-stubs.sh exports CLAUDEHUT_WORKER=1"
else
  fail "L16 scaffold-stubs.sh" "scaffold session not tagged CLAUDEHUT_WORKER"
fi
# Behavioral: guard actually suppresses the block (not just present in source)
_tmpg="$(mktemp -d)"; ( cd "$_tmpg" && git init -q && git checkout -q -b feature/g && mkdir -p .claudehut/{specs,plans,memory,findings} )
if [[ -z "$(echo '{"prompt":"just write the code, skip the plan"}' | CLAUDE_PROJECT_DIR="$_tmpg" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" CLAUDEHUT_WORKER=1 bash "$pr_hook" 2>/dev/null)" ]]; then
  pass "L16 prompt-router.sh: CLAUDEHUT_WORKER suppresses skip-phrase block (behavioral)"
else
  fail "L16 prompt-router.sh" "CLAUDEHUT_WORKER did not suppress block at runtime"
fi
rm -rf "$_tmpg"

# Worker RED-step blocker: reuse-scan freshness gate must NOT block new files for
# workers (a worker's first action is writing a NEW *Test.java; scaffold writes no
# tests; a headless worker can't run /reuse-scan to clear a stale gate → hang).
# But the SCOPE gate must still fire for workers (defense-in-depth). Behavioral:
if grep -q 'CLAUDEHUT_WORKER' "$pre_tool" && grep -q 'reuse-scan freshness for new Java' "$pre_tool"; then
  pass "L16 pre-tool.sh: reuse-scan gate is CLAUDEHUT_WORKER-aware"
else
  fail "L16 pre-tool.sh" "reuse-scan gate not worker-aware — worker RED step (new *Test.java) hangs on stale scan"
fi
_rt="$(mktemp -d)"
(
  cd "$_rt" && git init -q && git checkout -q -b feature/rt
  mkdir -p .claudehut/{specs,plans,memory} src
  tid=feature-rt
  echo d > ".claudehut/specs/${tid}-design.md"; echo c > ".claudehut/specs/${tid}-contract.md"
  printf '# Plan\n## Task 1: a\n**Files:**\n- create: `src/A.java`\n- test: `src/ATest.java`\n**Depends on:** (none)\n**Parallel group:** 1\n- [ ] complete\n---\n' > ".claudehut/plans/${tid}-plan.md"
  echo x > .claudehut/memory/stack-signals.md
)
# WORKER + new in-plan test file (no reuse-scan present = stale) → expect ALLOW (empty)
out_allow="$(echo "{\"tool_input\":{\"file_path\":\"$_rt/src/ATest.java\"}}" | CLAUDE_PROJECT_DIR="$_rt" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" CLAUDEHUT_WORKER=1 bash "$pre_tool" --tool edit 2>/dev/null)"
# WORKER + new OFF-plan file → expect DENY via scope (not reuse-scan)
out_scope="$(echo "{\"tool_input\":{\"file_path\":\"$_rt/src/Z.java\"}}" | CLAUDE_PROJECT_DIR="$_rt" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" CLAUDEHUT_WORKER=1 bash "$pre_tool" --tool edit 2>/dev/null)"
if [[ -z "$out_allow" ]]; then
  pass "L16 pre-tool.sh: worker may create in-plan new test file (reuse-scan bypassed)"
else
  fail "L16 pre-tool.sh" "worker blocked creating in-plan test file: $out_allow"
fi
if echo "$out_scope" | grep -q 'not in current plan'; then
  pass "L16 pre-tool.sh: scope gate STILL fires for worker (off-plan denied)"
else
  fail "L16 pre-tool.sh" "scope gate did not fire for worker off-plan write: $out_scope"
fi
rm -rf "$_rt"

# Scope-check path canonicalization (found by real Gradle e2e): worktrees live in
# temp dirs where CLAUDE_PROJECT_DIR (e.g. /tmp/x, a symlink) and the tool's
# file_path (canonical /private/tmp/x) differ → naive prefix-strip no-ops → every
# in-scope worker write wrongly denied. Reproduce with an explicit symlink so it
# fails cross-platform (not only on macOS /tmp).
if grep -q 'pwd -P' "$pre_tool"; then
  pass "L16 pre-tool.sh canonicalizes paths (pwd -P) for scope match"
else
  fail "L16 pre-tool.sh" "no path canonicalization — /tmp vs /private/tmp breaks worker scope-check"
fi
_creal="$(mktemp -d)/real"; mkdir -p "$_creal"
_clink="$(dirname "$_creal")/link"; ln -s "$_creal" "$_clink"
( cd "$_creal" && git init -q && git checkout -q -b feature/c && mkdir -p .claudehut/{specs,plans,memory} src )
echo d > "$_creal/.claudehut/specs/feature-c-design.md"; echo c > "$_creal/.claudehut/specs/feature-c-contract.md"
printf '# Plan\n## Task 1: a\n**Files:**\n- create: `src/A.java`\n**Depends on:** (none)\n**Parallel group:** 1\n- [ ] complete\n---\n' > "$_creal/.claudehut/plans/feature-c-plan.md"
echo x > "$_creal/.claudehut/memory/stack-signals.md"
# PROJECT_ROOT = symlink form, file_path = physical form, in-plan file → expect ALLOW
_creal_phys="$(cd "$_creal" && pwd -P)"
_cout="$(echo "{\"tool_input\":{\"file_path\":\"$_creal_phys/src/A.java\"}}" | CLAUDE_PROJECT_DIR="$_clink" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" CLAUDEHUT_WORKER=1 bash "$pre_tool" --tool edit 2>/dev/null)"
if [[ -z "$_cout" ]]; then
  pass "L16 pre-tool.sh: in-plan write allowed across symlink/canonical path mismatch"
else
  fail "L16 pre-tool.sh" "canonicalization fix failed — in-plan write denied across symlink: $_cout"
fi
rm -rf "$(dirname "$_creal")"

# Re-run safety (found by e2e): worktree branch must be force-created (-B) so a
# group retry after a failure doesn't collide with the prior attempt's branch.
if grep -q 'worktree add -B' "$rpg_script"; then
  pass "L16 run-parallel-group.sh uses 'worktree add -B' (re-run safe, no branch collision)"
else
  fail "L16 run-parallel-group.sh" "uses -b not -B — group re-run collides with stale branch"
fi

#==============================================================================
section "L17 Eval harness — deterministic scorer (no model calls)"
#==============================================================================
# Phase 2: score.sh must extract metrics correctly from a FINISHED run. Synthetic
# fixture (no build.gradle → gradle/pass@1 skipped, so this stays CI-gradle-free);
# asserts cost summing (main + worker .cost), findings, retries, wall extraction.
score_sh="$PLUGIN_ROOT/evals/score.sh"
if [[ -x "$score_sh" ]]; then pass "L17 evals/score.sh exists + executable"; else fail "L17 eval" "score.sh missing/not executable"; fi
if [[ -d "$PLUGIN_ROOT/evals/tasks/trivial-sum-bug/oracle" ]]; then pass "L17 seed fixture has a held-out oracle/"; else fail "L17 eval" "trivial-sum-bug oracle missing"; fi
# Oracle must NOT live in the fixture's repo/ tree (else pass@1 is self-graded).
if ls "$PLUGIN_ROOT/evals/tasks/trivial-sum-bug/repo/"**/.*Oracle*.java >/dev/null 2>&1 || \
   find "$PLUGIN_ROOT/evals/tasks/trivial-sum-bug/repo" -name '*Oracle*' 2>/dev/null | grep -q .; then
  fail "L17 eval" "oracle test leaked into repo/ — pass@1 would be self-graded"
else
  pass "L17 oracle is held out of repo/ (pass@1 not self-graded)"
fi
# Eval-integrity: "held out of repo/" is not enough — a claudehut `--print` agent
# reads $CLAUDE_PLUGIN_ROOT and can `cat` the oracle from the plugin repo. run.sh
# MUST point --plugin-dir at a sanitized copy with evals/ stripped (observed leak).
if grep -q 'PLUGIN_SANITIZED/evals' "$PLUGIN_ROOT/evals/run.sh" && grep -q 'plugin-dir "\$PLUGIN_SANITIZED"' "$PLUGIN_ROOT/evals/run.sh"; then
  pass "L17 run.sh sanitizes --plugin-dir (strips evals/ → agent can't read the held-out oracle)"
else
  fail "L17 eval" "run.sh exposes the real plugin repo via --plugin-dir → answer-key leak"
fi
e17="$(mktemp -d)"
( cd "$e17" && git init -q && git config user.email t@t && git config user.name t \
  && git commit -q --allow-empty -m base \
  && git commit -q --allow-empty -m "refactor(loop): a" \
  && git commit -q --allow-empty -m "refactor(loop): b" )
mkdir -p "$e17/.claudehut/findings" "$e17/.claudehut/logs"
printf '{"totals":{"critical":0,"high":2,"medium":1,"low":3}}\n' > "$e17/.claudehut/findings/x-findings.json"
printf '0.40\n' > "$e17/.claudehut/logs/a.cost"; printf '0.10\n' > "$e17/.claudehut/logs/b.cost"
echo '{"total_cost_usd":1.00}' > "$e17/claude.json"
row="$(bash "$score_sh" trivial-sum-bug "$e17" --claude-json "$e17/claude.json" --wall-ms 5000 --mode claudehut 2>/dev/null)"
[[ "$(echo "$row" | jq -r '.retries')" == "2" ]] && pass "L17 scorer: retries=2 (counts refactor(loop) commits)" || fail "L17 eval" "retries wrong: $(echo "$row"|jq -r .retries)"
[[ "$(echo "$row" | jq -r '.findings.high')" == "2" ]] && pass "L17 scorer: findings.high=2 (from findings.json)" || fail "L17 eval" "findings wrong: $row"
[[ "$(echo "$row" | jq -r '.cost_usd')" == "1.500000" ]] && pass "L17 scorer: cost=1.50 (main 1.00 + workers 0.40+0.10 summed)" || fail "L17 eval" "cost sum wrong: $(echo "$row"|jq -r .cost_usd)"
[[ "$(echo "$row" | jq -r '.wall_ms')" == "5000" ]] && pass "L17 scorer: wall_ms passthrough" || fail "L17 eval" "wall wrong"
[[ "$(echo "$row" | jq -r '.pass_at_1')" == "null" ]] && pass "L17 scorer: pass@1 null when ungradeable (no build.gradle/gradle)" || pass "L17 scorer: pass@1 graded (gradle present)"
[[ "$(echo "$row" | jq -r '.terminal_status')" == "unknown" ]] && pass "L17 scorer: terminal_status=unknown when result JSON lacks subtype" || fail "L17 eval" "terminal_status wrong: $(echo "$row"|jq -r .terminal_status)"
[[ "$(echo "$row" | jq -r '.is_error')" == "false" ]] && pass "L17 scorer: is_error=false default" || fail "L17 eval" "is_error wrong: $(echo "$row"|jq -r .is_error)"
# A budget/turn-killed run must SELF-DESCRIBE, else pass@1=0 reads as "tried and produced a wrong fix"
# rather than "killed mid-pipeline on an unfinished tree" (the contamination the claudehut-mode run hit).
echo '{"total_cost_usd":1.24,"is_error":true,"subtype":"error_max_budget_usd"}' > "$e17/claude-killed.json"
krow="$(bash "$score_sh" trivial-sum-bug "$e17" --claude-json "$e17/claude-killed.json" --wall-ms 9000 --mode claudehut 2>/dev/null)"
[[ "$(echo "$krow" | jq -r '.terminal_status')" == "error_max_budget_usd" && "$(echo "$krow" | jq -r '.is_error')" == "true" ]] \
  && pass "L17 scorer: budget-kill row self-describes (terminal_status+is_error)" || fail "L17 eval" "kill row not self-describing: $krow"
rm -rf "$e17"; unset e17 row krow score_sh

#==============================================================================
section "L18 Adaptive-depth routing (Phase 3)"
#==============================================================================
# Phase 3: a route artifact (.claudehut/state/route-<task>.json) declares the
# pipeline depth; state.sh derives phase from it. Spec 3.1's proving test
# ("trivial→build+verify; migration→full+DB review") is fully deterministic — so
# it is proven here for free, no eval $. The real eval (3.2: does routing help)
# stays opt-in.
CL="$PLUGIN_ROOT/skills/route/scripts/classify.sh"
WR="$PLUGIN_ROOT/skills/route/scripts/write-route.sh"
[[ -x "$CL" && -x "$WR" ]] && pass "L18 route scripts exist + executable" || fail "L18 route" "classify/write-route missing or not exec"

# --- A. classifier proving matrix (conservative by construction) ---
[[ "$(bash "$CL" "$(cat "$PLUGIN_ROOT/evals/tasks/trivial-sum-bug/task.md")" | jq -r .profile)" == "quick" ]] \
  && pass "L18 classify: trivial-sum-bug → quick" || fail "L18 route" "trivial not classified quick"
mig="$(bash "$CL" "Add a Flyway migration to add a status column to the orders table")"
[[ "$(echo "$mig"|jq -r .profile)" == "full" && "$(echo "$mig"|jq -r .db_review)" == "true" ]] \
  && pass "L18 classify: migration → full + db_review" || fail "L18 route" "migration wrong: $mig"
# Conservative boundary: a feature description must NOT be quick (locks against a
# later tweak silently widening quick and stripping the design gate from features).
[[ "$(bash "$CL" "implement a new payment service with retry and idempotency" | jq -r .profile)" == "full" ]] \
  && pass "L18 classify: feature → full (not quick) — boundary locked" || fail "L18 route" "feature leaked into quick"
[[ "$(bash "$CL" "" | jq -r .profile)" == "full" ]] \
  && pass "L18 classify: empty/unknown → full (conservative default)" || fail "L18 route" "default not full"

# --- B. write-route.sh → artifact shape + validation ---
R18="$(mktemp -d)"; ( cd "$R18" && git init -q && git checkout -q -b feature/r18 2>/dev/null )
mkdir -p "$R18/.claudehut"
( cd "$R18" && CLAUDE_PROJECT_DIR="$R18" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$WR" quick --reason t ) >/dev/null 2>&1
rj="$R18/.claudehut/state/route-feature-r18.json"
if [[ -f "$rj" ]] && [[ "$(jq -r .profile "$rj")" == "quick" ]] && [[ "$(jq -c '.phases' "$rj")" == '["build","loop"]' ]]; then
  pass "L18 write-route quick → profile=quick, phases=[build,loop]"
else
  fail "L18 route" "quick route.json wrong: $(cat "$rj" 2>/dev/null)"
fi
( cd "$R18" && CLAUDE_PROJECT_DIR="$R18" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$WR" full --db-review --reason t ) >/dev/null 2>&1
if [[ "$(jq -r .profile "$rj")" == "full" ]] && [[ "$(jq '.phases|length' "$rj")" == "6" ]] && [[ "$(jq -r '.flags.db_review' "$rj")" == "true" ]]; then
  pass "L18 write-route full --db-review → 6 phases + db_review flag"
else
  fail "L18 route" "full route.json wrong: $(cat "$rj")"
fi
if ( cd "$R18" && CLAUDE_PROJECT_DIR="$R18" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$WR" bogus ) >/dev/null 2>&1; then
  fail "L18 route" "write-route accepted a bogus profile"
else
  pass "L18 write-route rejects an invalid profile (exit≠0)"
fi
rm -rf "$R18"

# --- C. route-aware phase derivation (the core) ---
D18="$(mktemp -d)"; export CLAUDE_PROJECT_DIR="$D18"; export CLAUDEHUT_TASK_ID="t18"
mkdir -p "$D18/.claudehut/"{specs,plans,findings,state}
(
  source "$PLUGIN_ROOT/hooks/lib/state.sh"
  rp="$D18/.claudehut/state/route-t18.json"
  printf '{"profile":"quick","phases":["build","loop"]}\n' > "$rp"
  [[ "$(claudehut_phase)" == "build" ]] && pass "L18 derive: quick + no findings → build" || fail "L18 route" "quick→build got $(claudehut_phase)"
  printf '{"decision":"fail"}\n' > "$D18/.claudehut/findings/t18-findings.json"
  [[ "$(claudehut_phase)" == "loop" ]]  && pass "L18 derive: quick + findings fail → loop" || fail "L18 route" "quick fail got $(claudehut_phase)"
  printf '{"decision":"pass"}\n' > "$D18/.claudehut/findings/t18-findings.json"
  [[ "$(claudehut_phase)" == "done" ]]  && pass "L18 derive: quick + pass → done (SKIPS learn)" || fail "L18 route" "quick pass got $(claudehut_phase)"
  rm -f "$D18/.claudehut/findings/t18-findings.json"
  printf '{"profile":"full","phases":["brainstorm","spec","plan","build","loop","learn"]}\n' > "$rp"
  [[ "$(claudehut_phase)" == "brainstorm" ]] && pass "L18 derive: full + no design → brainstorm (== legacy waterfall)" || fail "L18 route" "full got $(claudehut_phase)"
  rm -f "$rp"; echo design > "$D18/.claudehut/specs/t18-design.md"
  [[ "$(claudehut_phase)" == "spec" ]] && pass "L18 derive: no route + design exists → legacy fallthrough (never strands in-flight task)" || fail "L18 route" "legacy got $(claudehut_phase)"
  rm -f "$D18/.claudehut/specs/t18-design.md"
  [[ "$(claudehut_phase)" == "route" ]] && pass "L18 derive: fresh (no route, no design) → route" || fail "L18 route" "fresh got $(claudehut_phase)"
)
unset CLAUDEHUT_TASK_ID; rm -rf "$D18"; unset CLAUDE_PROJECT_DIR

# --- D. gate (pre-tool) respects the route, no pre-tool phase-name coupling ---
G18="$(mktemp -d)"; ( cd "$G18" && git init -q && git checkout -q -b feature/g18 2>/dev/null )
mkdir -p "$G18/.claudehut/state" "$G18/.claudehut/findings" "$G18/src/main/java"
export CLAUDE_PROJECT_DIR="$G18"
echo "{\"tool_input\":{\"file_path\":\"$G18/src/main/java/A.java\"}}" | bash "$PLUGIN_ROOT/hooks/pre-tool.sh" --tool edit > "$G18/o.json" 2>&1
jq -e '.hookSpecificOutput.permissionDecision=="deny"' "$G18/o.json" >/dev/null 2>&1 \
  && pass "L18 gate: route phase blocks src/ edit" || fail "L18 route" "route should block src: $(cat "$G18/o.json")"
printf '{"profile":"quick","phases":["build","loop"]}\n' > "$G18/.claudehut/state/route-feature-g18.json"
echo "{\"tool_input\":{\"file_path\":\"$G18/src/main/java/A.java\"}}" | bash "$PLUGIN_ROOT/hooks/pre-tool.sh" --tool edit > "$G18/o2.json" 2>&1
if jq -e '.hookSpecificOutput.permissionDecision=="deny"' "$G18/o2.json" >/dev/null 2>&1; then
  fail "L18 route" "quick build wrongly blocked a NEW src file (reuse-scan gate should self-disable): $(cat "$G18/o2.json")"
else
  pass "L18 gate: quick route → build allows new src/ (plan-scope + reuse-scan gates self-disable)"
fi
# quick + verify FAIL → phase=loop. Quick has NO plan to re-open build (as full
# does via refactor-injection), so the editable window must include loop — else
# the "fix the finding inline" instruction is un-followable (the gate would lock src).
printf '{"decision":"fail"}\n' > "$G18/.claudehut/findings/feature-g18-findings.json"
echo "{\"tool_input\":{\"file_path\":\"$G18/src/main/java/A.java\"}}" | bash "$PLUGIN_ROOT/hooks/pre-tool.sh" --tool edit > "$G18/o3.json" 2>&1
if jq -e '.hookSpecificOutput.permissionDecision=="deny"' "$G18/o3.json" >/dev/null 2>&1; then
  fail "L18 route" "quick+loop (verify-fail) wrongly blocked the inline fix — quick failure path is gated shut: $(cat "$G18/o3.json")"
else
  pass "L18 gate: quick + verify-fail (loop) allows inline src fix (post-route window build+loop is one editable phase)"
fi
cd "$PLUGIN_ROOT"; rm -rf "$G18"; unset CLAUDE_PROJECT_DIR CL WR mig rj

#==============================================================================
section "L19 JIT relevance retrieval + usefulness prior (Phase 4)"
#==============================================================================
# Phase 4: dispatch prompts retrieve the top-k RELEVANT learnings (not head-200
# recency) ranked by relevance × an outcome-signal usefulness prior. The proving
# suite is deterministic (no model calls) — run it and surface its result.
if bash "$PLUGIN_ROOT/tests/integration/retrieve-relevant-test.sh" >/tmp/p4.log 2>&1; then
  p4_pass=$(grep -oE 'Pass=[0-9]+' /tmp/p4.log | head -1 | cut -d= -f2)
  pass "L19 Phase 4 proving tests: ${p4_pass:-?} assertions green (retrieval ranking + usefulness round-trip, no model calls)"
else
  fail "L19 Phase 4" "see /tmp/p4.log"; sed -n '1,40p' /tmp/p4.log
fi

#==============================================================================
section "L20 Seeded-learnings retrieval eval (relevance > recency, deterministic)"
#==============================================================================
# Phase-4 eval at corpus scale: a seeded 14-entry corpus whose relevant entries
# are the OLDEST proves the ranker discriminates by RELEVANCE not recency
# (precision/recall + no-padding + anti-circular package-vs-tag discriminators).
# Deterministic, no model calls. Proves the MECHANISM, not "improves real runs".
if bash "$PLUGIN_ROOT/evals/retrieval/run-retrieval-eval.sh" >/tmp/p4eval.log 2>&1; then
  e_pass=$(grep -oE 'Pass=[0-9]+' /tmp/p4eval.log | head -1 | cut -d= -f2)
  pass "L20 retrieval eval: ${e_pass:-?} assertions green (relevance 100% vs recency 0% on the seeded corpus)"
else
  fail "L20 retrieval eval" "see /tmp/p4eval.log"; sed -n '1,40p' /tmp/p4eval.log
fi

#==============================================================================
section "L21 Capability fixture (slugify-convention) — free validity guards"
#==============================================================================
# The vehicle for the Phase-4 CAPABILITY A/B: a task whose correct answer depends
# on an arbitrary project convention the base model can't guess. Gradle-verified
# once (standard '-' impl FAILS the oracle, '__' impl PASSES → it discriminates);
# the free, fast guards below keep it honest in CI. The paid 2-run A/B itself
# (seeded vs unseeded) is opt-in.
slug="$PLUGIN_ROOT/evals/tasks/slugify-convention"
if find "$slug/repo" -name '*Oracle*' 2>/dev/null | grep -q .; then
  fail "L21 capability" "slugify oracle leaked into repo/ — agent could read the '__' convention"
else
  pass "L21 slugify oracle held out of repo/ (convention not visible to the agent)"
fi
grep -q '__' "$slug/oracle/SlugifyOracleTest.java" 2>/dev/null \
  && pass "L21 oracle pins the '__' convention (a standard '-' impl fails it)" || fail "L21 capability" "oracle does not assert the '__' convention"
# the seeded convention must be retrievable from the task intent (else the A/B is moot)
_cap="$(mktemp -d)"; mkdir -p "$_cap/.claudehut/memory"
cp "$slug/seed-learnings.jsonl" "$_cap/.claudehut/memory/learnings.jsonl"
printf -- '- web: mvc\n' > "$_cap/.claudehut/memory/stack-signals.md"
if bash "$PLUGIN_ROOT/skills/learn/scripts/retrieve-relevant.sh" "$_cap" "$(cat "$slug/task.md")" t-cap 5 | grep -qi 'double underscore'; then
  pass "L21 task intent retrieves the seeded slug convention (capability A/B is wired)"
else
  fail "L21 capability" "task intent does not surface the seeded convention"
fi
rm -rf "$_cap"; unset slug _cap

#==============================================================================
section "L22 Cost telemetry + budget gate + model-tier (Phase 5)"
#==============================================================================
# Phase 5: per-worker cost/token telemetry (.cost + run-summary.jsonl), a
# worker-pool budget gate, and three-tier model resolution. Deterministic, no
# model calls (static fixtures).
if bash "$PLUGIN_ROOT/tests/integration/phase5-telemetry-test.sh" >/tmp/p5.log 2>&1; then
  p5_pass=$(grep -oE 'Pass=[0-9]+' /tmp/p5.log | head -1 | cut -d= -f2)
  pass "L22 Phase 5 telemetry/budget/model tests: ${p5_pass:-?} assertions green (no model calls)"
else
  fail "L22 Phase 5" "see /tmp/p5.log"; sed -n '1,40p' /tmp/p5.log
fi
# Static wiring guards (the helpers are dead code unless actually called):
rpg="$PLUGIN_ROOT/skills/build/scripts/run-parallel-group.sh"
_have() { grep -qF -- "$1" "$2"; }
if _have '--output-format json' "$rpg" && _have "jq -r '.result // empty'" "$rpg" \
   && _have 'capture-telemetry.sh' "$rpg" && _have 'budget-gate.sh' "$rpg" \
   && _have 'resolve-worker-model.sh' "$rpg" && _have '2>"$OUT_FILE.log"' "$rpg"; then
  pass "L22 run-parallel-group wires telemetry+gate+model+stream-split (atomic pieces coexist)"
else
  fail "L22 wiring" "run-parallel-group.sh missing one of: --output-format json / jq result-recover / capture-telemetry / budget-gate / resolve-model / stream-split"
fi
grep -q 'Exit 3' "$PLUGIN_ROOT/skills/build/SKILL.md" && grep -q 'budget-breach.json' "$PLUGIN_ROOT/skills/build/SKILL.md" \
  && pass "L22 build/SKILL.md surfaces Exit 3 budget halt (consumer wired)" || fail "L22 wiring" "SKILL.md does not surface Exit 3"
grep -q 'undercounted' "$PLUGIN_ROOT/evals/score.sh" \
  && fail "L22 wiring" "score.sh still carries the stale 'undercounted' disclaimer" \
  || pass "L22 score.sh disclaimer dropped (build workers now emit .cost)"
unset rpg

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
