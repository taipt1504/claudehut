#!/usr/bin/env bash
# tests/e2e/simulated/full-workflow.sh
#
# Simulated E2E: walks a fixture Java project through ALL 6 phases of the
# ClaudeHut workflow by scripting the artifacts an LLM agent would create at
# each phase boundary. Validates hooks fire correctly, state derives correctly,
# and the final state shows all expected outputs.
#
# Does NOT require Claude Code installed — runs purely as bash + hooks.
#
# Each "step" is what a real agent would do; we verify the plugin's response.

set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
PASS=0; FAIL=0
declare -a FAIL_LIST=()

pass() { printf "  \033[32m✓\033[0m %s\n" "$1"; PASS=$((PASS+1)); }
fail() { printf "  \033[31m✗\033[0m %s :: %s\n" "$1" "$2"; FAIL=$((FAIL+1)); FAIL_LIST+=("$1: $2"); }
section() { echo ""; echo "----- $1 -----"; }

# Set up fixture project
TMPDIR=$(mktemp -d)
cd "$TMPDIR"
git init -q
git config user.email "test@test"
git config user.name "Test"
git checkout -q -b main 2>/dev/null
echo "# fixture" > README.md
git add -q .; git commit -q -m "init"

# Mock Java project
mkdir -p src/main/java/com/x/user src/test/java/com/x/user src/main/resources/db/migration
cat > pom.xml <<'POM'
<?xml version="1.0"?>
<project>
  <groupId>com.x</groupId>
  <artifactId>fixture</artifactId>
  <version>1.0.0</version>
  <dependencies>
    <dependency><groupId>org.springframework.boot</groupId><artifactId>spring-boot-starter-webflux</artifactId></dependency>
    <dependency><groupId>org.springframework.boot</groupId><artifactId>spring-boot-starter-data-r2dbc</artifactId></dependency>
    <dependency><groupId>org.postgresql</groupId><artifactId>r2dbc-postgresql</artifactId></dependency>
    <dependency><groupId>org.mapstruct</groupId><artifactId>mapstruct</artifactId><version>1.5.5.Final</version></dependency>
  </dependencies>
</project>
POM
git add -q .; git commit -q -m "scaffold project"

# Initialize .claudehut/
mkdir -p .claudehut/{specs,plans,memory,findings,reuse-scans}
cp "$PLUGIN_ROOT/templates/claudehut-config.template.json" .claudehut/claudehut-config.json
cat > .claudehut/memory/stack-signals.md <<'STACK'
- build_tool: maven
- java_version: 21
- spring_boot: 3.3.4
- web: webflux
- orm: r2dbc
- db: postgresql
- messaging: none
- cache: none
- mapper: mapstruct
- serialization: jackson
- detected_at: 2025-05-27T08:00:00Z
STACK
git add -q .; git commit -q -m "init claudehut"

# Create a feature branch — task starts
git checkout -q -b feature/add-user-endpoint

export CLAUDE_PROJECT_DIR="$TMPDIR"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "$PLUGIN_ROOT/hooks/lib/state.sh"

#==============================================================================
echo "===== E2E SIMULATED FULL WORKFLOW ====="
echo "Fixture: $TMPDIR"
echo "Branch: $(claudehut_branch)  Task: $(claudehut_task_id)"
echo ""
#==============================================================================

#----- STEP 0: SessionStart should bind task + derive phase=brainstorm -----
section "STEP 0 — SessionStart"
out=$(echo '{}' | bash "$PLUGIN_ROOT/hooks/session-start.sh")
phase=$(claudehut_phase)
[[ "$phase" == "brainstorm" ]] && pass "phase=brainstorm derived" || fail "phase" "expected brainstorm, got $phase"
echo "$out" | jq -e '.hookSpecificOutput.additionalContext | contains("MANDATORY next: /claudehut:brainstorm")' >/dev/null \
  && pass "SessionStart instructs brainstorm" || fail "session-start" "missing brainstorm instruction"
echo "$out" | jq -e '.hookSpecificOutput.additionalContext | contains("web=webflux")' >/dev/null \
  && pass "SessionStart shows stack" || fail "session-start" "stack not surfaced"

#----- STEP 1: User prompt triggers feature intent — should advance to brainstorm skill -----
section "STEP 1 — User prompt 'add endpoint'"
out=$(echo '{"prompt":"add endpoint to fetch user purchase history"}' | bash "$PLUGIN_ROOT/hooks/prompt-router.sh")
echo "$out" | jq -e '.hookSpecificOutput.additionalContext | contains("Phase=brainstorm")' >/dev/null \
  && pass "prompt-router enforces brainstorm skill" || fail "prompt-router" "missing brainstorm hint: $out"

#----- STEP 2: Agent tries to edit src/ in brainstorm → blocked -----
section "STEP 2 — Premature src/ edit blocked"
out=$(echo "{\"tool_input\":{\"file_path\":\"$TMPDIR/src/main/java/com/x/user/UserController.java\"}}" \
  | bash "$PLUGIN_ROOT/hooks/pre-tool.sh" --tool edit)
echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
  && pass "PreToolUse blocks src/ edit in brainstorm" || fail "pre-tool" "should block: $out"

#----- STEP 3: Agent runs reuse-scan + creates design doc -----
section "STEP 3 — Reuse-scan + design doc"
TASK_ID=$(claudehut_task_id)

# Simulated reuse-scan result
cat > .claudehut/reuse-scans/${TASK_ID}.json <<EOF
{
  "task_id": "$TASK_ID",
  "topic": "user purchase history endpoint",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "integrations_used": ["grep"],
  "candidates": []
}
EOF
pass "reuse-scan artifact written"

# Simulated design doc (agent writes after Socratic + reuse decision)
cat > .claudehut/specs/${TASK_ID}-design.md <<'DESIGN'
# User Purchase History Endpoint — Design

## Overview
Expose GET /api/v1/users/me/purchases for the authenticated user.

## Components
- UserPurchaseHandler — WebFlux handler reading auth from ServerWebExchange
- UserPurchaseRepository — R2DBC repository with cursor-paginated query
- PurchaseResponseMapper — MapStruct mapper Entity → Response DTO

## Data flow
1. Caller GET /api/v1/users/me/purchases?cursor=X&size=20
2. Handler extracts user from JWT, delegates to repo
3. Repo returns Flux<Purchase> with cursor pagination
4. Mapper transforms to PurchaseResponse DTO
5. Handler returns ServerResponse.ok().bodyValue(...)

## Error handling
- 401 if no JWT
- 400 if cursor invalid
- 500 mapped via GlobalExceptionHandler

## Testing strategy
- Unit: handler with mocked repo, StepVerifier
- Integration: WebTestClient + Testcontainers Postgres

## NFR
| NFR | Budget | Verification |
|-----|--------|--------------|
| Latency p95 | ≤ 200ms | Gatling smoke |
| Throughput | ≥ 500 req/s | Gatling load |
| Auth | JWT required | reviewer-security |
| Logging | INFO with {userId,cursor,duration} | manual |
DESIGN

# Self-review
bash "$PLUGIN_ROOT/skills/brainstorm/scripts/design-doc-selfreview.sh" \
  .claudehut/specs/${TASK_ID}-design.md >/dev/null \
  && pass "design-doc-selfreview passes" || fail "design-selfreview" "rejected good doc"

# Phase should advance
phase=$(claudehut_phase)
[[ "$phase" == "spec" ]] && pass "phase auto-advanced to spec" || fail "phase" "expected spec, got $phase"

#----- STEP 4: Agent writes contract -----
section "STEP 4 — Contract doc"
cat > .claudehut/specs/${TASK_ID}-contract.md <<'CONTRACT'
# Purchase History Contract

## Acceptance criteria

### AC-1: empty for new user
GIVEN authenticated user with no purchases
WHEN GET /api/v1/users/me/purchases
THEN HTTP 200 returned
AND body.items is empty array

### AC-2: paginated
GIVEN authenticated user with 50 purchases
WHEN GET /api/v1/users/me/purchases?size=20
THEN HTTP 200 returned
AND body.items has 20 elements

### AC-3: unauthenticated rejected
GIVEN unauthenticated request
WHEN GET /api/v1/users/me/purchases
THEN HTTP 401 returned

## API shape

GET /api/v1/users/me/purchases?cursor=&size=20
Authorization: Bearer <jwt>

Response 200:
{ "items": [...], "nextCursor": null }

Errors:
- 401: ProblemDetail type=urn:problem:auth-required
- 400: ProblemDetail type=urn:problem:invalid-cursor

## Error responses

```json
{
  "type": "urn:problem:auth-required",
  "title": "Authentication required",
  "status": 401,
  "detail": "JWT bearer token required"
}
```

## Edge cases

| # | Case | Expected |
|---|------|----------|
| 1 | cursor invalid | 400 |
| 2 | size > 100 | 400 |
| 3 | empty purchases | 200 with [] |

## NFR

| NFR | Budget |
|-----|--------|
| Latency p95 | 200ms |
| Throughput | 500 req/s |

## Data contract

No schema delta required (existing `purchases` table).

## Test surface

| Type | Files |
|------|-------|
| Unit | UserPurchaseHandlerTest.java |
| Integration | UserPurchaseIT.java |
CONTRACT

bash "$PLUGIN_ROOT/skills/spec/scripts/validate-contract.sh" \
  .claudehut/specs/${TASK_ID}-contract.md >/dev/null \
  && pass "validate-contract passes" || fail "validate-contract" "rejected good contract"

phase=$(claudehut_phase)
[[ "$phase" == "plan" ]] && pass "phase auto-advanced to plan" || fail "phase" "expected plan, got $phase"

#----- STEP 5: Agent writes plan -----
section "STEP 5 — Plan doc"
cat > .claudehut/plans/${TASK_ID}-plan.md <<'PLAN'
# Purchase History Plan

**Goal:** Implement GET /api/v1/users/me/purchases with pagination.
**Tech stack:** web=webflux, orm=r2dbc, mapper=mapstruct, ser=jackson

## Task 1: Add PurchaseResponse DTO + Mapper

**Covers:** AC-1

**Files:**
- create: `src/main/java/com/x/user/PurchaseResponse.java`
- create: `src/main/java/com/x/user/PurchaseMapper.java`
- test:   `src/test/java/com/x/user/PurchaseMapperTest.java`

**RED:**
```bash
./gradlew test --tests 'com.x.user.PurchaseMapperTest.shouldMapEntityToResponse'
```

**GREEN:** Define record + MapStruct mapper with @Mapper(componentModel="spring", unmappedTargetPolicy=ERROR).

**Verify:**
```bash
./gradlew test --tests 'com.x.user.PurchaseMapperTest'
```

**Depends on:** (none)
**Risk:** none
**Estimate:** 3 min

- [ ] complete

## Task 2: Add Handler with empty-case response

**Covers:** AC-1, AC-3

**Files:**
- create: `src/main/java/com/x/user/UserPurchaseHandler.java`
- create: `src/main/java/com/x/user/UserPurchaseRouter.java`
- test:   `src/test/java/com/x/user/UserPurchaseHandlerTest.java`

**RED:**
```bash
./gradlew test --tests 'com.x.user.UserPurchaseHandlerTest.shouldReturn200WithEmpty'
```

**GREEN:** Implement handler returning Mono<ServerResponse> with empty list.

**Verify:**
```bash
./gradlew test --tests 'com.x.user.UserPurchaseHandlerTest'
```

**Depends on:** Task 1
**Risk:** none
**Estimate:** 5 min

- [ ] complete

## Task 3: Add pagination logic

**Covers:** AC-2

**Files:**
- modify: `src/main/java/com/x/user/UserPurchaseHandler.java`
- create: `src/main/java/com/x/user/UserPurchaseRepository.java`
- test:   `src/test/java/com/x/user/UserPurchaseHandlerTest.java`

**RED:**
```bash
./gradlew test --tests 'com.x.user.UserPurchaseHandlerTest.shouldPaginate'
```

**GREEN:** Add cursor-based pagination in handler + R2DBC repository.

**Verify:**
```bash
./gradlew test --tests 'com.x.user.UserPurchaseHandlerTest'
```

**Depends on:** Task 2
**Risk:** none
**Estimate:** 5 min

- [ ] complete
PLAN

bash "$PLUGIN_ROOT/skills/plan/scripts/plan-placeholder-scan.sh" \
  .claudehut/plans/${TASK_ID}-plan.md >/dev/null \
  && pass "plan-placeholder-scan passes" || fail "plan-placeholder" "rejected clean plan"

bash "$PLUGIN_ROOT/skills/plan/scripts/plan-spec-coverage.sh" \
  .claudehut/plans/${TASK_ID}-plan.md \
  .claudehut/specs/${TASK_ID}-contract.md >/dev/null \
  && pass "plan-spec-coverage passes (3/3 ACs)" || fail "plan-coverage" "coverage check failed"

phase=$(claudehut_phase)
[[ "$phase" == "build" ]] && pass "phase auto-advanced to build" || fail "phase" "expected build, got $phase"

#----- STEP 6: Builder picks Task 1 — RED + GREEN + commit -----
section "STEP 6 — Build Task 1"

# Reuse-scan freshness check should pass (we wrote it in step 3, < 10 min ago)
# Simulated RED — create failing test file
cat > src/test/java/com/x/user/PurchaseMapperTest.java <<'TEST'
package com.x.user;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.assertThat;
public class PurchaseMapperTest {
    @Test void shouldMapEntityToResponse() {
        // RED — will fail because PurchaseMapper doesn't exist yet
        assertThat(true).isTrue();
    }
}
TEST

# PreToolUse should ALLOW (build phase + file in plan + reuse-scan fresh)
out=$(echo "{\"tool_input\":{\"file_path\":\"$TMPDIR/src/main/java/com/x/user/PurchaseMapper.java\"}}" \
  | bash "$PLUGIN_ROOT/hooks/pre-tool.sh" --tool edit 2>&1)
if echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
  fail "pre-tool" "blocked file that's in plan + has fresh reuse-scan: $out"
else
  pass "pre-tool allows file in plan during build phase"
fi

# Simulated GREEN — create the mapper + response
cat > src/main/java/com/x/user/PurchaseResponse.java <<'JAVA'
package com.x.user;
public record PurchaseResponse(String id, String item) {}
JAVA
cat > src/main/java/com/x/user/PurchaseMapper.java <<'JAVA'
package com.x.user;
public class PurchaseMapper {
    public PurchaseResponse toResponse(String id, String item) {
        return new PurchaseResponse(id, item);
    }
}
JAVA

# Tick checkbox for Task 1
sed -i.bak 's|- \[ \] complete|- [x] complete|' .claudehut/plans/${TASK_ID}-plan.md
# But only first occurrence
# Actually sed -i acts on every match; redo by line
mv .claudehut/plans/${TASK_ID}-plan.md.bak .claudehut/plans/${TASK_ID}-plan.md
awk 'BEGIN{count=0} /^- \[ \] complete/{if(count<1){gsub(/\[ \]/,"[x]"); count++}} {print}' \
  .claudehut/plans/${TASK_ID}-plan.md > .claudehut/plans/${TASK_ID}-plan.md.new
mv .claudehut/plans/${TASK_ID}-plan.md.new .claudehut/plans/${TASK_ID}-plan.md
pass "Task 1 marked complete in plan"

# Phase still build (Tasks 2, 3 unchecked)
phase=$(claudehut_phase)
[[ "$phase" == "build" ]] && pass "phase still=build with 2 unchecked" || fail "phase" "expected build, got $phase"

#----- STEP 7: Builder completes Task 2 + 3 -----
section "STEP 7 — Complete remaining tasks"
# Tick all remaining
sed -i.bak2 's|- \[ \] complete|- [x] complete|g' .claudehut/plans/${TASK_ID}-plan.md
rm .claudehut/plans/${TASK_ID}-plan.md.bak2

# All checked → phase advances to loop
phase=$(claudehut_phase)
[[ "$phase" == "loop" ]] && pass "phase auto-advanced to loop" || fail "phase" "expected loop, got $phase"

#----- STEP 8: Verify/Review via the REAL shard+aggregate round-trip -----
section "STEP 8 — Verify/Review gates green (real shard+aggregate round-trip)"

# Verifier writes the verify stanza (per-gate status format).
cat > .claudehut/findings/${TASK_ID}-findings.json <<'FINDINGS'
{
  "verify": {
    "build":    {"status": "pass"},
    "test":     {"status": "pass", "passed": 14, "failed": 0, "skipped": 0},
    "coverage": {"status": "pass", "line": 0.85, "branch": 0.78},
    "lint":     {"status": "pass"},
    "static":   {"status": "pass"}
  },
  "reviewers": {}
}
FINDINGS

# Orchestrator fires SubagentStop markers for each dispatched reviewer.
for r in claudehut-reviewer-security claudehut-reviewer-perf claudehut-reviewer-reactive claudehut-reviewer-style claudehut-reviewer-mapping; do
  echo "{\"agent_type\":\"$r\"}" | bash "$PLUGIN_ROOT/hooks/subagent-stop.sh" >/dev/null
done
pass "SubagentStop markers written (step 8)"

# Reviewers write their shards (medium + low only → 0 critical/high → pass).
e2e_shard_dir=".claudehut/findings/$TASK_ID"; mkdir -p "$e2e_shard_dir"
cat > "$e2e_shard_dir/reviewer-perf.json" <<'S'
{"reviewer":"claudehut-reviewer-perf","completed_at":"t","findings":[{"severity":"medium","category":"perf","file":"src/main/java/com/x/user/UserPurchaseHandler.java","line":42,"title":"minor n+1 risk","detail":"low-traffic path","suggestion":"consider @EntityGraph"}]}
S
cat > "$e2e_shard_dir/reviewer-style.json" <<'S'
{"reviewer":"claudehut-reviewer-style","completed_at":"t","findings":[{"severity":"low","category":"style","file":"src/main/java/com/x/user/PurchaseResponse.java","line":3,"title":"missing javadoc","detail":"record lacks @param docs","suggestion":"add javadoc"}]}
S

# Real aggregate (single reader, merges shards + verify stanza).
bash "$PLUGIN_ROOT/skills/verify-review/scripts/aggregate-findings.sh" "$TASK_ID" >/dev/null
pass "aggregate-findings.sh ran (step 8 real round-trip)"

# Discriminating: old code (no shard reader) → totals all 0; new code → medium=1 low=1.
[[ "$(jq -r '.totals.medium' .claudehut/findings/${TASK_ID}-findings.json)" == "1" ]] \
  && pass "step8 totals.medium=1 (discriminating: old code → 0)" || fail "step8 medium" "expected 1, got $(jq -r '.totals.medium' .claudehut/findings/${TASK_ID}-findings.json)"
[[ "$(jq -r '.totals.low' .claudehut/findings/${TASK_ID}-findings.json)" == "1" ]] \
  && pass "step8 totals.low=1 (discriminating: old code → 0)" || fail "step8 low" "expected 1, got $(jq -r '.totals.low' .claudehut/findings/${TASK_ID}-findings.json)"
[[ "$(jq -r '.decision' .claudehut/findings/${TASK_ID}-findings.json)" == "pass" ]] \
  && pass "step8 decision=pass (0 crit + 0 high)" || fail "step8 decision" "expected pass, got $(jq -r '.decision' .claudehut/findings/${TASK_ID}-findings.json)"

phase=$(claudehut_phase)
[[ "$phase" == "learn" ]] && pass "phase auto-advanced to learn" || fail "phase" "expected learn, got $phase"

#----- STEP 9: Stop hook surfaces "invoke /claudehut:learn" -----
section "STEP 9 — Stop hook"
# Default mode: non-blocking systemMessage (user can still stop).
out=$(bash "$PLUGIN_ROOT/hooks/stop.sh")
echo "$out" | jq -e '.systemMessage | contains("claudehut:learn")' >/dev/null \
  && pass "Stop hook surfaces learn reminder (default, non-blocking)" \
  || fail "stop" "missing learn reminder: $out"

# Opt-in enforcement: enable, expect decision=block.
cat > .claudehut/claudehut-config.json <<'CFG'
{"phase":{"stop_enforcement_enabled":true}}
CFG
out=$(bash "$PLUGIN_ROOT/hooks/stop.sh")
echo "$out" | jq -e '.decision == "block" and (.reason | contains("claudehut:learn"))' >/dev/null \
  && pass "Stop hook blocks under opt-in enforcement" \
  || fail "stop" "missing decision=block under enforcement: $out"
rm -f .claudehut/claudehut-config.json

#----- STEP 10: Learn writes learnings.jsonl -----
section "STEP 10 — Learnings persisted"
sig="sha256:$(echo -n "use serverwebexchange to read userinfo header:pattern" | shasum -a 256 | cut -d' ' -f1)"
cat > .claudehut/memory/learnings.jsonl <<EOF
{"id":"learn-2025-05-27-001","ts":"2025-05-27T11:05:00Z","session_id":"e2e-test","task_id":"$TASK_ID","category":"pattern","title":"Use ServerWebExchange to read userInfo header","content":"In WebFlux handlers, read auth headers via ServerWebExchange.getRequest().getHeaders() — never inject HttpServletRequest (servlet API not available). Cache parsed user in Reactor Context for downstream operators.","signature":"$sig","files_touched":["src/main/java/com/x/user/UserPurchaseHandler.java"],"hits":1,"tags":["webflux","security","header","context-propagation"]}
EOF
pass "learnings entry appended"

# Secret-scan should pass
bash "$PLUGIN_ROOT/skills/learn/scripts/secret-scan.sh" .claudehut/memory/learnings.jsonl >/dev/null \
  && pass "learnings clean of secrets" || fail "secret-scan" "false positive on learning"

phase=$(claudehut_phase)
[[ "$phase" == "done" ]] && pass "phase auto-advanced to done" || fail "phase" "expected done, got $phase"

#----- STEP 11: Stop hook suggests claudehut-finish -----
section "STEP 11 — Done state"
out=$(bash "$PLUGIN_ROOT/hooks/stop.sh")
# Done state uses non-blocking systemMessage (top-level, per Stop hook schema).
echo "$out" | jq -e '.systemMessage | contains("claudehut-finish")' >/dev/null \
  && pass "Stop hook suggests claudehut-finish" || fail "stop" "missing finish suggestion: $out"

#----- FINAL VERIFICATION: all expected artifacts present -----
section "FINAL — All artifacts present"
[[ -f ".claudehut/specs/${TASK_ID}-design.md" ]] && pass "design doc exists" || fail "artifact" "design missing"
[[ -f ".claudehut/specs/${TASK_ID}-contract.md" ]] && pass "contract doc exists" || fail "artifact" "contract missing"
[[ -f ".claudehut/plans/${TASK_ID}-plan.md" ]] && pass "plan doc exists" || fail "artifact" "plan missing"
[[ -f ".claudehut/findings/${TASK_ID}-findings.json" ]] && pass "findings exists" || fail "artifact" "findings missing"
[[ -f ".claudehut/memory/learnings.jsonl" ]] && pass "learnings exists" || fail "artifact" "learnings missing"
[[ -f ".claudehut/reuse-scans/${TASK_ID}.json" ]] && pass "reuse-scan exists" || fail "artifact" "reuse-scan missing"

# Plan is fully checked
grep -q "^- \[ \]" .claudehut/plans/${TASK_ID}-plan.md \
  && fail "plan completion" "unchecked items remain" \
  || pass "plan fully checked"

# Findings decision = pass
[[ "$(jq -r '.decision' .claudehut/findings/${TASK_ID}-findings.json)" == "pass" ]] \
  && pass "findings decision=pass" || fail "findings" "decision != pass"

# Learnings contains task entry
grep -qF "\"task_id\":\"$TASK_ID\"" .claudehut/memory/learnings.jsonl \
  && pass "learnings contains task entry" || fail "learnings" "task entry missing"

#==============================================================================
echo ""
echo "===== E2E SUMMARY ====="
echo ""
TOTAL=$((PASS+FAIL))
printf "Total: %d   \033[32mPass: %d\033[0m   \033[31mFail: %d\033[0m\n" "$TOTAL" "$PASS" "$FAIL"

if [[ "$FAIL" -gt 0 ]]; then
  echo ""
  echo "FAILURES:"
  for f in "${FAIL_LIST[@]}"; do echo "  - $f"; done
fi

cd "$PLUGIN_ROOT"
rm -rf "$TMPDIR"

[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
