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
  mkdir -p "$w/.claude/claudehut"
  # v0.12: a task dir is the one `start` prints (it never adopts a pre-created dir). The artifacts are staged
  # outside the repo and moved into that dir once the task is open (after the git setup, so base = the fixture HEAD).
  local d; d="$(mktemp -d)"
  printf '{\n  "worktree": { "baseRef": "head" }\n}\n' > "$w/.claude/settings.json"
  # HARD GUARD: if baseRef=head isn't actually set, the run tests the WRONG (default) base — abort.
  [ "$(jq -r '.worktree.baseRef // empty' "$w/.claude/settings.json" 2>/dev/null)" = "head" ] \
    || { echo "FATAL: settings.json baseRef!=head — fixture setup failed, aborting probe" >&2; exit 3; }
  printf '# PROJECT\nBuild: grep/file verify for this demo (do NOT run Gradle). Base package com.x.\n' > "$w/.claude/claudehut/PROJECT.md"
  cat > "$d/spec.md" <<'S'
# Spec: spine + dependent handlers
> id: 0001-spine · profile: feature · route: full · rev: 1 · status: approved · date: 2026-06-09

## 1. Context
A shared base processor, then two handlers that extend it. The reuse scan decided `new`.

## 3. Requirements
| ID | Requirement (EARS) | Acceptance (GWT) |
|---|---|---|
| AC-001 | THE SYSTEM SHALL drive every handler through BaseProcessor.process | GIVEN valid input WHEN a handler runs THEN BaseProcessor.process drives it |
| AC-002 | WHEN an order is handled THE SYSTEM SHALL validate it | GIVEN invalid order input WHEN OrderHandler runs THEN it is rejected |
| AC-003 | WHEN a payment is handled THE SYSTEM SHALL validate it | GIVEN invalid payment input WHEN PaymentHandler runs THEN it is rejected |

## 4. Flow
```mermaid
sequenceDiagram
  Caller->>BaseProcessor: process(in)
  BaseProcessor->>OrderHandler: handle(in)
```

## 5. Contracts
none

## 6. Decisions
| ID | Decision (Y-statement) | Rejected options | Confirmation | Status |
|---|---|---|---|---|
| D-1 | In the context of the handlers, facing shared processing steps, we decided for a BaseProcessor template method that each handler extends to achieve one processing path, accepting a base class | Copy the steps into each handler | AC-001 test | accepted |
S
  printf '%s\n' '# Reuse scan' '| Dimension | Existing asset | Decision | Fit | Impact | Effort |' '|---|---|---|---|---|---|' '| processor/handler | none | new | 1 | low | M |' > "$d/reuse-scan.md"
  cat > "$d/plan.md" <<'PL'
# Plan: spine + dependent handlers
> id: 0001-spine · spec-rev: 1 · route: full · rev: 1 · status: approved

## 1. Approach
Implements D-1: BaseProcessor (Phase A, committed) → two handlers that EXTEND BaseProcessor (Phase B,
parallel). Build: grep/file verify (do NOT run Gradle).

## 2. Design
```mermaid
sequenceDiagram
  Caller->>OrderHandler: process(in)
  OrderHandler->>OrderHandler: handle(in) via BaseProcessor template method
```
BaseProcessor.process() is the template method (Phase A); each handler overrides handle() (Phase B).

## 3. Interfaces & Data
| Element | Change | Contract | Req |
|---|---|---|---|
| `BaseProcessor` | new (done) | `BaseProcessor#process(in: String): String`, abstract `handle(in: String): String` | AC-001 |
| `OrderHandler` | new | `class OrderHandler extends BaseProcessor` overriding handle(), plus OrderValidator real checks | AC-002 |
| `PaymentHandler` | new | `class PaymentHandler extends BaseProcessor` overriding handle(), plus PaymentValidator real checks | AC-003 |

## 4. Tasks
### Phase A — foundation  (DONE — already committed on the feature branch)
| ID | Goal | Files | Test first | Verify | Depends | Req |
|---|---|---|---|---|---|---|
| T-001 | BaseProcessor abstract base (process + template method) | src/main/java/com/x/proc/BaseProcessor.java | n/a (done) | `test -f src/main/java/com/x/proc/BaseProcessor.java` | — | AC-001 |

### Phase B — handlers  (parallel — each EXTENDS BaseProcessor from Phase A; multi-file, dispatch-worthy)
| ID | Goal | Files | Test first | Verify | Depends | Req |
|---|---|---|---|---|---|---|
| T-002 [P] | OrderHandler: extends BaseProcessor + validator + test | src/main/java/com/x/proc/OrderHandler.java, src/main/java/com/x/proc/OrderValidator.java, src/test/java/com/x/proc/OrderHandlerTest.java | OrderHandlerTest#handleAndInvalidInput | `grep -q 'extends BaseProcessor' src/main/java/com/x/proc/OrderHandler.java && test -f src/main/java/com/x/proc/OrderValidator.java` | T-001 | AC-002 |
| T-003 [P] | PaymentHandler: extends BaseProcessor + validator + test | src/main/java/com/x/proc/PaymentHandler.java, src/main/java/com/x/proc/PaymentValidator.java, src/test/java/com/x/proc/PaymentHandlerTest.java | PaymentHandlerTest#handleAndInvalidInput | `grep -q 'extends BaseProcessor' src/main/java/com/x/proc/PaymentHandler.java && test -f src/main/java/com/x/proc/PaymentValidator.java` | T-001 | AC-003 |

## 5. Risks & Rollback
- Demo fixture only; rollback: revert the commit.
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
  local id; id="$( cd "$w" && CLAUDE_PROJECT_DIR="$w" "$ST" --session "$sid" start --route full --profile feature --slug spine 2>/dev/null | sed -n 1p )"
  [ "$id" = 0001-spine ] || { echo "FATAL: start opened '$id', not 0001-spine (the prompt names 0001-spine) — fixture setup failed, aborting probe" >&2; exit 3; }
  mv "$d"/* "$w/.claude/claudehut/tasks/$id/" && rmdir "$d"
  ( cd "$w"
    CLAUDE_PROJECT_DIR="$w" "$ST" --session "$sid" set-reuse-scan --artifact .claude/claudehut/tasks/0001-spine/reuse-scan.md >/dev/null 2>&1
    CLAUDE_PROJECT_DIR="$w" "$ST" --session "$sid" set-spec .claude/claudehut/tasks/0001-spine/spec.md >/dev/null 2>&1
    CLAUDE_PROJECT_DIR="$w" "$ST" --session "$sid" set-plan .claude/claudehut/tasks/0001-spine/plan.md >/dev/null 2>&1
    CLAUDE_PROJECT_DIR="$w" "$ST" --session "$sid" set-phase implement >/dev/null 2>&1 )
  # v0.12 M3: set-spec/set-plan run doclint, so a fixture the gate refuses would leave plan_approved=false and the
  # probe would measure a run that started in the wrong phase. Fail loudly instead of silently.
  jq -e '.plan_approved==true and .phase=="implement"' "$w/.claude/claudehut/tasks/$id/task.json" >/dev/null 2>&1 \
    || { echo "FATAL: the pre-state did not record the plan (doclint refused a fixture?) — aborting probe" >&2; exit 3; }
  ( cd "$w" && echo "ahead/behind origin/HEAD: $(git rev-list --left-right --count origin/HEAD...HEAD 2>/dev/null)" ) >&2
}

read -r -d '' PROMPT <<'PR'
You are operating under ClaudeHut, RESUMING at the Implement phase. Phase A (T-001 — BaseProcessor) is
ALREADY implemented and COMMITTED on the current feature branch. The reuse-scan, spec, and plan for task
0001-spine are recorded and approved (plan_approved=true). Execute the remaining Phase B (T-002, T-003)
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
  # RES-X3: the old harness guard was cost==0 && impl_total==0 — it only caught a run that never started.
  # The failure that actually misreports is a run that DID work with the plugin absent (demoted, load error,
  # wrong scope): real cost, real tool calls, and pass=false, which reads as a code defect rather than a
  # harness one. Detect it from an OBSERVABLE rather than a guessed stream field: if the plugin plane were
  # live, a run that dispatched anything would show at least one claudehut skill invocation or agent.
  # Any explicit plugin_errors key in the stream also counts, and costs nothing if the key never appears.
  chsig=$(jq -rc 'select(.type=="assistant")|.message.content[]?|select(.type=="tool_use")|
                  ((.name//"") + " " + ((.input.skill//"") + (.input.subagent_type//"")))' "$R" 2>/dev/null \
          | grep -c 'claudehut' || echo 0)
  perr=$(jq -rc '.. | objects | select(has("plugin_errors")) | 1' "$R" 2>/dev/null | grep -c . || echo 0)
  herr=false
  { [ "${cost:-0}" = "0" ] && [ "${impl_total:-0}" = "0" ]; } && herr=true          # never started
  [ "${perr:-0}" -gt 0 ] && herr=true                                              # runtime said so
  { [ "${cost:-0}" != "0" ] && [ "${chsig:-0}" -eq 0 ]; } && herr=true             # ran, plugin never spoke
  jq -nc --argjson i "$i" --argjson fan "${fanout:-0}" --argjson it "${impl_total:-0}" --argjson cdj "${cdj:-0}" \
     --argjson bl "${blocked:-0}" --argjson bo "${builton:-0}" --argjson cost "${cost:-0}" --argjson pass "$pass" --argjson herr "$herr" --arg wd "$W" \
     '{trial:$i,fanout_max_per_msg:$fan,implementers_total:$it,check_disjoint_used:$cdj,implementer_blocked:$bl,handlers_extend_base:$bo,cost_usd:$cost,PASS:$pass,harness_error:$herr,workdir:$wd}' | tee -a "$OUT"
done
echo "done -> $OUT"
