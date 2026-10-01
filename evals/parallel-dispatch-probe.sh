#!/usr/bin/env bash
# Live probe: does the REAL implement skill make the MAIN THREAD fan out a phased plan's [P] batch into
# parallel claudehut-implementer subagents? (Issue 1 verification — v0.3.2.)
#
# Methodology (per advisor):
#  - --model OPUS on the orchestrator: the dispatch decision is the MAIN THREAD, which in the user's real
#    (screenshot) sessions is Opus 4.8 (implementers are sonnet via frontmatter regardless of --model).
#    Verifying a sonnet orchestrator answers the wrong question.
#  - Pre-set, pre-gated state via a fixed --session-id so the model STARTS at Implement and does NOT
#    re-derive the upstream phases (isolates the Implement dispatch decision).
#  - Substantial, dispatch-worthy [P] tasks (multi-file, real logic) verified by grep — never Gradle.
#  - NEUTRAL prompt: never says "parallel" / "in one message"; the skill must drive the decision.
#  - Detector is msg-id-GROUPED (NOT per-event): stream-json emits each tool_use as its own event sharing
#    message.id; per-event counting undercounts concurrent dispatch (a known prior artifact).
#
# PASS: max implementer dispatches sharing ONE message.id >= 2  (parallel fan-out happened).
# Usage: parallel-dispatch-probe.sh [trials] [model]   (COSTS TOKENS)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
N="${1:-1}"; MODEL="${2:-opus}"
OUT="$ROOT/evals/results/parallel-dispatch.jsonl"; mkdir -p "$(dirname "$OUT")"
SAN="$(mktemp -d)/plugin"; cp -R "$ROOT" "$SAN"; rm -rf "$SAN/evals" "$SAN/docs" "$SAN/.git"
TO="$(command -v gtimeout || command -v timeout || true)"   # macOS has neither; --max-budget-usd bounds the run
ST="$SAN/bin/claudehut-state"

mkfx() { # fixture repo + approved phased plan + PRE-GATED state for $SID; echoes nothing
  local w="$1" sid="$2"; mkdir -p "$w"; cp -R "$ROOT/evals/tasks/_fixtures/servlet-jpa/." "$w/" 2>/dev/null || mkdir -p "$w/src"
  mkdir -p "$w/.claude/claudehut"
  # v0.12: a task dir is the one `start` prints (it never adopts a pre-created dir). The artifacts are staged
  # outside the repo and moved into that dir once the task is open (after the git setup, so base = the fixture HEAD).
  local d; d="$(mktemp -d)"
  printf '# PROJECT\nBuild: grep/file verify for this demo (do NOT run Gradle). Base package com.x.\n' > "$w/.claude/claudehut/PROJECT.md"
  cat > "$d/spec.md" <<'S'
# Spec: orders + payments
> id: 0001-orders · profile: feature · route: full · rev: 1 · status: approved · date: 2026-06-08

## 1. Context
Two independent domain services, then a controller that uses both. The reuse scan decided `new`.

## 3. Requirements
| ID | Requirement (EARS) | Acceptance (GWT) |
|---|---|---|
| AC-001 | WHEN a valid order is created THE SYSTEM SHALL persist an Order | GIVEN a valid order WHEN createOrder THEN an Order is persisted |
| AC-002 | WHEN a valid payment is charged THE SYSTEM SHALL record a Payment | GIVEN a valid payment WHEN charge THEN a Payment is recorded |
| AC-003 | WHEN checkout is called THE SYSTEM SHALL create the order and charge it | GIVEN a valid order WHEN checkout THEN OrderService then PaymentService run |

## 4. Flow
```mermaid
sequenceDiagram
  Client->>OrderController: checkout
  OrderController->>OrderService: createOrder
  OrderController->>PaymentService: charge
```

## 5. Contracts
none

## 6. Decisions
| ID | Decision (Y-statement) | Rejected options | Confirmation | Status |
|---|---|---|---|---|
| D-1 | In the context of orders and payments, facing two independent domains, we decided for two separate services wired by one controller to achieve parallel delivery, accepting one more service bean | One combined service | AC-001, AC-002, AC-003 tests | accepted |
S
  printf '%s\n' '# Reuse scan' '| Dimension | Existing asset | Decision | Fit | Impact | Effort |' '|---|---|---|---|---|---|' '| order/payment service | none | new | 1 | low | M |' > "$d/reuse-scan.md"
  cat > "$d/plan.md" <<'PL'
# Plan: orders + payments
> id: 0001-orders · spec-rev: 1 · route: full · rev: 1 · status: approved

## 1. Approach
Implements D-1: build two INDEPENDENT services (Order, Payment) with real validation logic, then a controller
using both. Build: grep/file verify for this demo (do NOT run Gradle).

## 2. Design
```mermaid
sequenceDiagram
  OrderController->>OrderService: createOrder(OrderRequest)
  OrderController->>PaymentService: charge(PaymentRequest)
```
The two services are independent; the controller is wired after both exist.

## 3. Interfaces & Data
| Element | Change | Contract | Req |
|---|---|---|---|
| `OrderService` | new | `OrderServiceImpl#createOrder(OrderRequest): Order`, cancelOrder, refund; real null/amount/status validation | AC-001 |
| `PaymentService` | new | `PaymentServiceImpl#charge(PaymentRequest): Payment`, refund; real amount validation | AC-002 |
| `OrderController` | new | `OrderController#checkout()` calls OrderService then PaymentService | AC-003 |

## 4. Tasks
### Phase 1 — domain / service  (parallel — independent components)
| ID | Goal | Files | Test first | Verify | Depends | Req |
|---|---|---|---|---|---|---|
| T-001 [P] | OrderService: createOrder/cancelOrder/refund with validation | src/main/java/com/x/order/Order.java, src/main/java/com/x/order/OrderService.java, src/main/java/com/x/order/OrderServiceImpl.java, src/test/java/com/x/order/OrderServiceTest.java | OrderServiceTest#createCancelInvalidAmount | `grep -q createOrder src/main/java/com/x/order/OrderServiceImpl.java && grep -q cancelOrder src/main/java/com/x/order/OrderServiceImpl.java && grep -q refund src/main/java/com/x/order/OrderServiceImpl.java` | — | AC-001 |
| T-002 [P] | PaymentService: charge/refund with validation | src/main/java/com/x/pay/Payment.java, src/main/java/com/x/pay/PaymentService.java, src/main/java/com/x/pay/PaymentServiceImpl.java, src/test/java/com/x/pay/PaymentServiceTest.java | PaymentServiceTest#chargeRefundInvalidAmount | `grep -q charge src/main/java/com/x/pay/PaymentServiceImpl.java && grep -q refund src/main/java/com/x/pay/PaymentServiceImpl.java` | — | AC-002 |

### Phase 2 — API / controller  (after phase 1)
| ID | Goal | Files | Test first | Verify | Depends | Req |
|---|---|---|---|---|---|---|
| T-003 | OrderController wiring both services | src/main/java/com/x/web/OrderController.java | OrderControllerTest#placeAndCheckout | `grep -q OrderService src/main/java/com/x/web/OrderController.java && grep -q PaymentService src/main/java/com/x/web/OrderController.java` | T-001, T-002 | AC-003 |

## 5. Risks & Rollback
- Demo fixture only; rollback: revert the commit.
PL
  ( cd "$w" && git init -q && git config user.email t@t && git config user.name t && git add -A && git commit -qm base \
    && git remote add origin . && git fetch -q origin && git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main ) >/dev/null 2>&1
  # PRE-STATE: full route + reuse-scan + spec + plan recorded (plan_approved=true), phase=implement → start at Implement
  local id; id="$( cd "$w" && CLAUDE_PROJECT_DIR="$w" "$ST" --session "$sid" start --route full --profile feature --slug orders 2>/dev/null | sed -n 1p )"
  [ "$id" = 0001-orders ] || { echo "FATAL: start opened '$id', not 0001-orders (the prompt names 0001-orders) — fixture setup failed, aborting probe" >&2; exit 3; }
  mv "$d"/* "$w/.claude/claudehut/tasks/$id/" && rmdir "$d"
  ( cd "$w"
    CLAUDE_PROJECT_DIR="$w" "$ST" --session "$sid" set-reuse-scan --artifact .claude/claudehut/tasks/0001-orders/reuse-scan.md >/dev/null 2>&1
    CLAUDE_PROJECT_DIR="$w" "$ST" --session "$sid" set-spec .claude/claudehut/tasks/0001-orders/spec.md >/dev/null 2>&1
    CLAUDE_PROJECT_DIR="$w" "$ST" --session "$sid" set-plan .claude/claudehut/tasks/0001-orders/plan.md >/dev/null 2>&1
    CLAUDE_PROJECT_DIR="$w" "$ST" --session "$sid" set-phase implement >/dev/null 2>&1 )
  # v0.12 M3: set-spec/set-plan run doclint, so a fixture the gate refuses would leave plan_approved=false and the
  # probe would measure a run that started in the wrong phase. Fail loudly instead of silently.
  jq -e '.plan_approved==true and .phase=="implement"' "$w/.claude/claudehut/tasks/$id/task.json" >/dev/null 2>&1 \
    || { echo "FATAL: the pre-state did not record the plan (doclint refused a fixture?) — aborting probe" >&2; exit 3; }
}

read -r -d '' PROMPT <<'PR'
You are operating under ClaudeHut and RESUMING at the Implement phase (phase 5 of 7). The reuse-scan, spec,
and plan for task 0001-orders are already complete, recorded, and APPROVED (plan_approved=true). DO NOT
re-run Discover, Brainstorm, Spec, or Plan. Invoke the claudehut:implement skill and execute the approved
plan at .claude/claudehut/tasks/0001-orders/plan.md to completion, following the skill exactly. Use each
plan row's Verify command literally (grep/test — do NOT run Gradle). Report what you did.
PR

echo "model=$MODEL trials=$N  (opus orchestrator; pre-gated at Implement; substantial [P] tasks; neutral prompt)"
for ((i=1;i<=N;i++)); do
  SID="$(uuidgen)"; W="$(mktemp -d)/run"; mkfx "$W" "$SID"
  ( cd "$W" && CLAUDE_PROJECT_DIR="$W" CLAUDE_PLUGIN_ROOT="$SAN" \
      ${TO:+$TO 800} claude --print --plugin-dir "$SAN" --session-id "$SID" --output-format stream-json --verbose \
      --model "$MODEL" --max-budget-usd 6.00 --permission-mode acceptEdits "$PROMPT" < /dev/null ) > "$W/.r.jsonl" 2>"$W/.err" || true

  R="$W/.r.jsonl"
  fanout=$(jq -rc 'select(.type=="assistant") | {id:.message.id, n:([.message.content[]?|select(.type=="tool_use")|select(.name=="Task" or .name=="Agent")|select((.input.subagent_type//"")|test("implementer"))]|length)}' "$R" 2>/dev/null \
    | jq -s 'if length==0 then 0 else (group_by(.id)|map(map(.n)|add)|max) end' 2>/dev/null); fanout="${fanout:-0}"
  impl_total=$(jq -rc 'select(.type=="assistant")|.message.content[]?|select(.type=="tool_use")|select(.name=="Task" or .name=="Agent")|select((.input.subagent_type//"")|test("implementer"))|.name' "$R" 2>/dev/null | wc -l | tr -d ' ')
  types=$(jq -rc 'select(.type=="assistant")|.message.content[]?|select(.type=="tool_use")|select(.name=="Task" or .name=="Agent")|.input.subagent_type // "?"' "$R" 2>/dev/null | sort | uniq -c | tr '\n' ';')
  cdj=$(jq -rc 'select(.type=="assistant")|.message.content[]?|select(.type=="tool_use")|select(.name=="Bash")|.input.command' "$R" 2>/dev/null | grep -c 'check-disjoint' || true)
  # MAIN-THREAD writes only — exclude writes whose path is under a worktree (those are the implementers',
  # surfaced at top level by stream-json). High main-only writes = the inline-conflation failure mode.
  mainwrites=$(jq -rc 'select(.type=="assistant")|.message.content[]?|select(.type=="tool_use")|select(.name=="Write" or .name=="Edit")|.input.file_path // ""' "$R" 2>/dev/null | grep -v '/.claude/worktrees/' | grep -c '.' || true)
  tcreate=$(jq -rc 'select(.type=="assistant")|.message.content[]?|select(.type=="tool_use")|.name' "$R" 2>/dev/null | grep -c 'TaskCreate' || true)
  tupdate=$(jq -rc 'select(.type=="assistant")|.message.content[]?|select(.type=="tool_use")|.name' "$R" 2>/dev/null | grep -c 'TaskUpdate' || true)
  cost=$(jq -rc 'select(.type=="result")|.total_cost_usd // 0' "$R" 2>/dev/null | tail -1)
  pass=false; [ "${fanout:-0}" -ge 2 ] && pass=true
  herr=false; [ "${cost:-0}" = "0" ] && [ -z "$types" ] && [ "$mainwrites" = "0" ] && herr=true

  jq -nc --argjson i "$i" --argjson fan "${fanout:-0}" --argjson it "${impl_total:-0}" --argjson cdj "${cdj:-0}" \
     --argjson mw "${mainwrites:-0}" --argjson tc "${tcreate:-0}" --argjson tu "${tupdate:-0}" --argjson cost "${cost:-0}" \
     --argjson pass "$pass" --argjson herr "$herr" --arg ty "$types" --arg wd "$W" \
     '{trial:$i,fanout_max_per_msg:$fan,implementers_total:$it,check_disjoint_used:$cdj,main_thread_writes:$mw,taskcreate:$tc,taskupdate:$tu,cost_usd:$cost,PASS_fanout:$pass,harness_error:$herr,types:$ty,workdir:$wd}' | tee -a "$OUT"
done
echo "done -> $OUT"
