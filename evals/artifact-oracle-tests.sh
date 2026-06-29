#!/usr/bin/env bash
# Self-test for evals/lib/artifact-checks.sh (v0.7 benchmark P0). FREE, deterministic, no Claude.
# Proves each artifact oracle DISCRIMINATES good output from vacuous output — i.e. it would actually go RED
# if an agent produced a placeholder plan, an all-5s reuse-scan, a spec-axis-only review, or skipped
# brainstorm persistence. This is what converts the Cognition/Standards guarantees from "the instruction is
# written" (conformance greps) to "the behavior is checkable" (regression-catchable).
# Run: evals/artifact-oracle-tests.sh   (exit 0 iff every oracle passes good AND fails bad)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
. "$ROOT/evals/lib/artifact-checks.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# Assert a check returns the expected rc (0=clean, 1=violation). Discards the check's own stdout.
expect() { # desc, expected_rc, check-invocation...
  local desc="$1" want="$2"; shift 2
  "$@" >/dev/null 2>&1; local got=$?
  [ "$got" -eq "$want" ] && ok "$desc (rc=$got)" || bad "$desc (want rc=$want, got $got)"
}

echo "== artifact oracle: reuse-scan Fit/Impact rigor =="
cat > "$T/scan-good.md" <<'EOF'
# Reuse Scan: x
## Summary
| Dimension | Existing asset | Decision | Fit | Impact | Effort |
|-----------|----------------|----------|-----|--------|--------|
| retries | Resilience4j @Retry (build.gradle) | framework | 5 | none — annotation only | S |
| idempotency | RequestKeyFilter — Foo.java:34 | extend | 4 | adds 1 branch; 2 callers | S |
| reaper | none | new — nothing fits | - | new class, isolated | M |
## Recommendation
Reuse Resilience4j; extend RequestKeyFilter; build reaper new.
EOF
expect "reuse-scan: GOOD (varied Fit, Impact present) passes" 0 check_reuse_scan_rigor "$T/scan-good.md"

cat > "$T/scan-blank.md" <<'EOF'
# Reuse Scan: x
## Summary
| Dimension | Existing asset | Decision | Fit | Impact | Effort |
|-----------|----------------|----------|-----|--------|--------|
| retries | Resilience4j @Retry | framework |  |  | S |
EOF
expect "reuse-scan: BAD (framework row, Fit blank + Impact blank) fails" 1 check_reuse_scan_rigor "$T/scan-blank.md"

cat > "$T/scan-vacuous.md" <<'EOF'
# Reuse Scan: x
## Summary
| Dimension | Existing asset | Decision | Fit | Impact | Effort |
|-----------|----------------|----------|-----|--------|--------|
| a | A.java:1 | adopt | 5 | x | S |
| b | B.java:2 | adopt | 5 | y | S |
| c | C.java:3 | extend | 5 | z | S |
EOF
expect "reuse-scan: BAD (3 rows all Fit=5, vacuous) fails" 1 check_reuse_scan_rigor "$T/scan-vacuous.md"

cat > "$T/scan-3varied.md" <<'EOF'
# Reuse Scan: x
## Summary
| Dimension | Existing asset | Decision | Fit | Impact | Effort |
|-----------|----------------|----------|-----|--------|--------|
| a | A.java:1 | framework | 5 | none | S |
| b | B.java:2 | extend | 4 | 2 callers | S |
| c | C.java:3 | adopt | 3 | wide blast | M |
EOF
expect "reuse-scan: GOOD (3 rows, VARIED Fit 5/4/3) passes — distinct-counter not shell-fragile" 0 check_reuse_scan_rigor "$T/scan-3varied.md"

cat > "$T/scan-lowfit.md" <<'EOF'
# Reuse Scan: x
## Summary
| Dimension | Existing asset | Decision | Fit | Impact | Effort |
|-----------|----------------|----------|-----|--------|--------|
| auth | OldAuth.java:9 | adopt | 2 | wide blast | M |
EOF
expect "reuse-scan: BAD (Fit=2 with no ## Evidence section) fails" 1 check_reuse_scan_rigor "$T/scan-lowfit.md"

echo "== artifact oracle: plan flow + no-placeholder =="
cat > "$T/plan-good.md" <<'EOF'
# Plan: x
> spec: t/spec.md · tier: full · status: draft
## 3. Implementation Flow
1. Controller receives CreateOrderRequest → 2. OrderService validates → 3. persists Order(status).
**T-002 sketch:**
```
class OrderService: create(req): validate(req); repo.save(toEntity(req)); return id
```
EOF
expect "plan: GOOD (§3 + sketch, no placeholder) passes" 0 check_plan_no_placeholder "$T/plan-good.md"

cat > "$T/plan-noflow.md" <<'EOF'
# Plan: x
> tier: full
## 4. Task Breakdown
| T-001 | do it | A.java | ATest#x | minimal | gradle | - | FR-1 |
EOF
expect "plan: BAD (no §3 Implementation Flow) fails" 1 check_plan_no_placeholder "$T/plan-noflow.md"

cat > "$T/plan-placeholder.md" <<'EOF'
# Plan: x
> tier: full
## 3. Implementation Flow
Request comes in, then we handle it.
**T-001 sketch:**
```
// TODO: implement logic, add error handling
```
EOF
expect "plan: BAD (placeholder 'implement logic'/'add error handling') fails" 1 check_plan_no_placeholder "$T/plan-placeholder.md"

cat > "$T/plan-fullnosketch.md" <<'EOF'
# Plan: x
> tier: full
## 3. Implementation Flow
1. A → 2. B → 3. persist.
## 4. Task Breakdown
| T-001 | behavior | A.java | ATest#x | minimal | gradle | - | FR-1 |
EOF
expect "plan: BAD (full tier, no per-task sketch) fails" 1 check_plan_no_placeholder "$T/plan-fullnosketch.md"

echo "== artifact oracle: brainstorm persisted + linked =="
cat > "$T/brainstorm-good.md" <<'EOF'
# Brainstorm: x
Option A: redis cache. Option B: in-memory.
Scores: A=420 B=380.
Premortem A: stampede. Premortem B: cold-start.
Recommendation: A.
EOF
cat > "$T/spec-good.md" <<'EOF'
# Spec: x
> id: 0001-x · type: feature
> brainstorm: tasks/0001-x/brainstorm.md
EOF
expect "brainstorm: GOOD (2 options + premortem + rec, spec linked) passes" 0 check_brainstorm_persisted "$T/brainstorm-good.md" "$T/spec-good.md"

expect "brainstorm: BAD (file missing entirely) fails" 1 check_brainstorm_persisted "$T/nope.md" "$T/spec-good.md"

cat > "$T/spec-nolink.md" <<'EOF'
# Spec: x
> id: 0001-x · type: feature
EOF
expect "brainstorm: BAD (spec missing '> brainstorm:' link) fails" 1 check_brainstorm_persisted "$T/brainstorm-good.md" "$T/spec-nolink.md"

echo "== artifact oracle: review Standards axis (FQN + duplication) =="
cat > "$T/review-good.md" <<'EOF'
# Review: x
| Item | Status | Severity | Evidence |
|------|--------|----------|----------|
| FQN-in-declaration | ✗ violated | MED | OrderService.java:12 `java.util.List<Foo>` inline — import it |
| cross-file duplication | ✗ violated | HIGH | toEnum duplicated ItemService.java:20, OrderService.java:31 |
| N+1 | ✓ | - | n-a |
EOF
expect "review: GOOD (FQN + duplication rows with file:line) passes" 0 check_review_standards_axis "$T/review-good.md"

cat > "$T/review-specaxis.md" <<'EOF'
# Review: x
| Item | Status | Severity | Evidence |
|------|--------|----------|----------|
| framework/jpa N+1 | ✗ | HIGH | OrderService.java:42 getItems() in loop |
| @Valid present | ✓ | - | Controller.java:18 |
EOF
expect "review: BAD (spec-axis only, no FQN/duplication) fails" 1 check_review_standards_axis "$T/review-specaxis.md"

echo
echo "ARTIFACT-ORACLES: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
