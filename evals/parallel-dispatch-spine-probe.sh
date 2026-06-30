#!/usr/bin/env bash
# Live probe (v0.5.0): does a SPINE-DEPENDENT phase fan out? — the exact case that broke in party-ms 0007.
# Phase A (T-001) commits a base class on the feature branch (local-only, branch AHEAD of origin). Phase B
# has two [P] tasks (T-002, T-003) that DEPEND on T-001 and must build on it. With worktree.baseRef=head,
# Phase-B worktrees fork from the current HEAD (which has the committed Phase A) and SEE it.
#
# PASS: fanout_max_per_msg >= 2 (Phase B fans out) AND implementers do NOT return BLOCKED (they saw the
#       committed Phase-A base — i.e. baseRef=head delivered the spine). Detector is msg-id-grouped.
#   --model OPUS (the orchestrator that had the bug). NEUTRAL-ish prompt. budget-capped.
# Usage: parallel-dispatch-spine-probe.sh [trials] [model]   (COSTS TOKENS)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
N="${1:-1}"; MODEL="${2:-opus}"
OUT="$ROOT/evals/results/parallel-dispatch-spine.jsonl"; mkdir -p "$(dirname "$OUT")"
SAN="$(mktemp -d)/plugin"; cp -R "$ROOT" "$SAN"; rm -rf "$SAN/evals" "$SAN/docs" "$SAN/.git"
ST="$SAN/bin/claudehut-state"

mkfx() {
  local w="$1" sid="$2"; mkdir -p "$w"; cp -R "$ROOT/evals/tasks/_fixtures/servlet-jpa/." "$w/" 2>/dev/null || mkdir -p "$w/src"
  local d="$w/.claude/claudehut/tasks/0001-spine"; mkdir -p "$d"   # creates .claude/ too
  printf '{\n  "worktree": { "baseRef": "head" }\n}\n' > "$w/.claude/settings.json"
  # HARD GUARD: if baseRef=head isn't actually set, the run tests the WRONG (default) base — abort.
  [ "$(jq -r '.worktree.baseRef // empty' "$w/.claude/settings.json" 2>/dev/null)" = "head" ] \
    || { echo "FATAL: settings.json baseRef!=head — fixture setup failed, aborting probe" >&2; exit 3; }
  printf '# PROJECT\nBuild: grep/file verify for this demo (do NOT run Gradle). Base package com.x.\n' > "$w/.claude/claudehut/PROJECT.md"
  printf '# Spec\n## 1. Problem\nA shared base processor, then two handlers that extend it.\n## 5. Acceptance Criteria\n- AC-001 GIVEN valid input WHEN a handler runs THEN BaseProcessor.process drives it.\n## 9. Decision\nBaseProcessor first, then OrderHandler + PaymentHandler build on it.\n' > "$d/spec.md"
  printf '%s\n' '# Reuse scan' '| Dimension | Existing asset | Decision | Fit | Impact | Effort |' '|---|---|---|---|---|---|' '| processor/handler | none | new | 1 | low | M |' > "$d/reuse-scan.md"
  cat > "$d/plan.md" <<'PL'
# Plan: spine + dependent handlers

> spec: tasks/0001-spine/spec.md · date: 2026-06-09 · status: approved
> approval: approved via AskUserQuestion
> REQUIRED SUB-SKILL: claudehut:implement

## 1. Decision & Approach
BaseProcessor (Phase A, committed) → two handlers that EXTEND BaseProcessor (Phase B, parallel).

## 2. Technical Context
Java 17. Build: grep/file verify (do NOT run Gradle).

## 3. Implementation Flow
BaseProcessor.process() template method (Phase A) → OrderHandler/PaymentHandler each extend it and override handle() (Phase B).
**T-002 sketch**: class OrderHandler extends BaseProcessor { handle() } + OrderValidator real checks.
**T-003 sketch**: class PaymentHandler extends BaseProcessor { handle() } + PaymentValidator real checks.

## 4. Task Breakdown

### Phase A — foundation  (DONE — already committed on the feature branch)
| ID | Goal | Files | Test first | Minimal change | Verify | Depends on | Req |
|----|------|-------|------------|----------------|--------|------------|-----|
| T-001 | BaseProcessor abstract base (process + template method) | src/main/java/com/x/proc/BaseProcessor.java | n/a (done) | n/a (done) | `test -f src/main/java/com/x/proc/BaseProcessor.java` | — | FR-1 |

### Phase B — handlers  (parallel — each EXTENDS BaseProcessor from Phase A; multi-file, dispatch-worthy)
| ID | Goal | Files | Test first | Minimal change | Verify | Depends on | Req |
|----|------|-------|------------|----------------|--------|------------|-----|
| T-002 [P] | OrderHandler: extends BaseProcessor + validator + test | src/main/java/com/x/proc/OrderHandler.java, src/main/java/com/x/proc/OrderValidator.java, src/test/java/com/x/proc/OrderHandlerTest.java | OrderHandlerTest covering handle + invalid input | `class OrderHandler extends BaseProcessor` overriding handle(), an OrderValidator with real checks, and the test | `grep -q 'extends BaseProcessor' src/main/java/com/x/proc/OrderHandler.java && test -f src/main/java/com/x/proc/OrderValidator.java` | T-001 | FR-2 |
| T-003 [P] | PaymentHandler: extends BaseProcessor + validator + test | src/main/java/com/x/proc/PaymentHandler.java, src/main/java/com/x/proc/PaymentValidator.java, src/test/java/com/x/proc/PaymentHandlerTest.java | PaymentHandlerTest covering handle + invalid input | `class PaymentHandler extends BaseProcessor` overriding handle(), a PaymentValidator with real checks, and the test | `grep -q 'extends BaseProcessor' src/main/java/com/x/proc/PaymentHandler.java && test -f src/main/java/com/x/proc/PaymentValidator.java` | T-001 | FR-3 |
PL
  ( cd "$w" && git init -q && git config user.email t@t && git config user.name t && git add -A && git commit -qm base ) >/dev/null 2>&1
  # bare origin at the BASE commit (so the 'fresh' default would NOT carry Phase A)
  local origin; origin="$(mktemp -d)/o.git"; git init -q --bare "$origin"
  ( cd "$w" && git remote add origin "$origin" && git push -q origin HEAD:main \
      && git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main && git fetch -q origin ) >/dev/null 2>&1
  # Phase A committed on the FEATURE branch, LOCAL-ONLY (branch now ahead of origin/HEAD)
  ( cd "$w" && git checkout -q -b feat/spine
    mkdir -p src/main/java/com/x/proc
    cat > src/main/java/com/x/proc/BaseProcessor.java <<'J'
package com.x.proc;
/** Phase-A foundation: committed on the feature branch, NOT pushed to origin. */
public abstract class BaseProcessor {
    public final String process(String in) { return handle(in); }
    protected abstract String handle(String in);
}
J
    git add -A && git commit -qm "T-001 — BaseProcessor (spine, local only)" ) >/dev/null 2>&1
  ( cd "$w" && CLAUDE_PROJECT_DIR="$w" \
      "$ST" --session "$sid" set-complexity full >/dev/null 2>&1
    CLAUDE_PROJECT_DIR="$w" "$ST" --session "$sid" set-reuse-scan --artifact .claude/claudehut/tasks/0001-spine/reuse-scan.md >/dev/null 2>&1
    CLAUDE_PROJECT_DIR="$w" "$ST" --session "$sid" set-spec .claude/claudehut/tasks/0001-spine/spec.md >/dev/null 2>&1
    CLAUDE_PROJECT_DIR="$w" "$ST" --session "$sid" set-plan .claude/claudehut/tasks/0001-spine/plan.md >/dev/null 2>&1
    CLAUDE_PROJECT_DIR="$w" "$ST" --session "$sid" set-profile feature >/dev/null 2>&1
    CLAUDE_PROJECT_DIR="$w" "$ST" --session "$sid" set-phase implement >/dev/null 2>&1 )
  ( cd "$w" && echo "ahead/behind origin/HEAD: $(git rev-list --left-right --count origin/HEAD...HEAD 2>/dev/null)" ) >&2
}

read -r -d '' PROMPT <<'PR'
You are operating under ClaudeHut, RESUMING at the Implement phase. Phase A (T-001 — BaseProcessor) is
ALREADY implemented and COMMITTED on the current feature branch. The reuse-scan, spec, and plan for task
0001-spine are recorded and approved; the write gate is OPEN. Execute the remaining Phase B (T-002, T-003)
by following the claudehut:implement skill exactly. Each handler must `extends BaseProcessor` (the committed
Phase-A class). Use each row's grep Verify command literally (do NOT run Gradle). Report what you did.
PR

echo "model=$MODEL trials=$N  (SPINE-dependent Phase B; baseRef=head; opus; pre-gated at Implement)"
for ((i=1;i<=N;i++)); do
  SID="$(uuidgen)"; W="$(mktemp -d)/run"; mkfx "$W" "$SID"
  ( cd "$W" && CLAUDE_PROJECT_DIR="$W" CLAUDE_PLUGIN_ROOT="$SAN" \
      claude --print --plugin-dir "$SAN" --session-id "$SID" --output-format stream-json --verbose \
      --model "$MODEL" --max-budget-usd 6.00 --permission-mode acceptEdits "$PROMPT" < /dev/null ) > "$W/.r.jsonl" 2>"$W/.err" || true
  R="$W/.r.jsonl"
  fanout=$(jq -rc 'select(.type=="assistant") | {id:.message.id, n:([.message.content[]?|select(.type=="tool_use")|select(.name=="Task" or .name=="Agent")|select((.input.subagent_type//"")|test("implementer"))]|length)}' "$R" 2>/dev/null \
    | jq -s 'if length==0 then 0 else (group_by(.id)|map(map(.n)|add)|max) end' 2>/dev/null); fanout="${fanout:-0}"
  impl_total=$(jq -rc 'select(.type=="assistant")|.message.content[]?|select(.type=="tool_use")|select(.name=="Task" or .name=="Agent")|select((.input.subagent_type//"")|test("implementer"))|.name' "$R" 2>/dev/null | wc -l | tr -d ' ')
  cdj=$(jq -rc 'select(.type=="assistant")|.message.content[]?|select(.type=="tool_use")|select(.name=="Bash")|.input.command' "$R" 2>/dev/null | grep -c 'check-disjoint' || true)
  # implementers that returned a BLOCKED *status line* (would mean they could NOT see the committed spine).
  # Match only the implementer status protocol ('**BLOCKED'/'BLOCKED:'), NOT prose "blocked" or addBlockedBy.
  blocked=$(jq -rc 'select(.type=="user")|.message.content[]?|select(.type=="tool_result")|(.content//""|if type=="array" then (.[0].text//"") else tostring end)' "$R" 2>/dev/null | grep -cE '^\*\*BLOCKED|^BLOCKED \(|^BLOCKED:' || true)
  # did the handlers actually end up extending BaseProcessor (built on the committed spine)?
  builton=$( ( cd "$W" && grep -lq 'extends BaseProcessor' src/main/java/com/x/proc/OrderHandler.java src/main/java/com/x/proc/PaymentHandler.java 2>/dev/null && echo 1 || echo 0 ) )
  cost=$(jq -rc 'select(.type=="result")|.total_cost_usd // 0' "$R" 2>/dev/null | tail -1)
  pass=false; [ "${fanout:-0}" -ge 2 ] && [ "${blocked:-0}" -eq 0 ] && pass=true
  herr=false; [ "${cost:-0}" = "0" ] && [ "${impl_total:-0}" = "0" ] && herr=true
  jq -nc --argjson i "$i" --argjson fan "${fanout:-0}" --argjson it "${impl_total:-0}" --argjson cdj "${cdj:-0}" \
     --argjson bl "${blocked:-0}" --argjson bo "${builton:-0}" --argjson cost "${cost:-0}" --argjson pass "$pass" --argjson herr "$herr" --arg wd "$W" \
     '{trial:$i,fanout_max_per_msg:$fan,implementers_total:$it,check_disjoint_used:$cdj,implementer_blocked:$bl,handlers_extend_base:$bo,cost_usd:$cost,PASS:$pass,harness_error:$herr,workdir:$wd}' | tee -a "$OUT"
done
echo "done -> $OUT"
