# Plan template (copy per task → `.claude/claudehut/tasks/NNNN-<slug>/plan.md`)

<!-- Synthesis: spec-kit plan/tasks templates (per-task ID/Files/Test-first/Verify/Depends-on/Req-ref,
     phase grouping, [P] parallel marker) · MADR Confirmation · ClaudeHut test-first Iron Law ·
     superpowers no-placeholder plans · mattpocock decision-rich PRD snippets (state machine/schema, not paths).
     The T-xxx table below is the DURABLE task breakdown — the native Claude Code task list
     (TaskCreate/TaskUpdate) is a per-session live MIRROR of it, created by the main thread on approval.

     DOC-AS-CONTRACT (v0.7): a plan that lists files but not HOW cannot be reviewed, so the code it
     produces cannot be controlled. §3 Implementation Flow + the per-task Sketch carry the HOW. They are
     RIGHT-SIZED by tier — full plans get the flow + a sketch per behavior task; small/bugfix/refactor get a
     2-3 sentence flow and a sketch ONLY where the control flow is non-obvious. This is the deliberate token
     spend that buys reviewability; it is not a license to pad. -->

```markdown
# Plan: <task title>

> spec: tasks/NNNN-<slug>/spec.md · brainstorm: tasks/NNNN-<slug>/brainstorm.md · tier: full|small · date: YYYY-MM-DD · status: draft|approved
> approval: <approved via AskUserQuestion | non-interactive run — proceeded with draft>
> REQUIRED SUB-SKILL: claudehut:implement

## 1. Decision & Approach
**Decision (from spec §9): <chosen option> — <one-line why>.**
2–3 sentences: the Spring components to add/modify, the migration strategy, how the reuse decision
(adopt/extend/new) shapes the work. The decision is restated HERE so the plan stands alone.

## 2. Technical Context
Java/Spring versions, build tool, test framework, exact build/test commands (verbatim from PROJECT.md).

## 3. Implementation Flow
**This is what a reviewer reads to understand HOW — the end-to-end change as a SEQUENCE, not a file list.**
Walk the request/event from entry to exit, naming the data that flows:
1. <entry: endpoint / listener / scheduler> receives <input shape> →
2. <component A> does <what> (validates / transforms / decides) →
3. calls <component B> → 4. persists / emits <what, with which fields>.

- **Data shape changes** — name the new/changed DTO · entity · event fields (name + type), not just "add a field".
- **Reuse anchors** — for each step that adopts/extends per the reuse-scan, name the existing type/dep used
  (e.g. "Resilience4j `RateLimiter` — not a hand-rolled token bucket"); this is what Review cross-checks.
- Add a Mermaid `sequenceDiagram` / `flowchart` ONLY when >3 steps or ≥2 collaborating components.

**Right-size:** `full` tier → full sequence + data shapes + a Mermaid diagram. `small`/`bugfix`/`refactor` →
2–3 sentences naming the touched path + the one data/shape change; skip the diagram.

## 4. Task Breakdown
One row per task. Every behavior task names its failing test FIRST (Iron Law). `[P]` = no dependency on
another task in the SAME phase and disjoint Files — safe to run as a parallel implementer. **Mark EVERY
intra-phase-independent task `[P]`, not just one** — the main thread fans out exactly the `[P]` tasks per
phase, so under-marking serializes Implement.

**Cell budgets (hard) — the TABLE stays a scannable dispatch index; the per-task Sketch below it carries the
detail:** `Test first` = `ClassName#method` only (≤60 chars — assertion detail lives in the spec's AC
section). `Minimal change` = intent phrase ≤30 words (no FQNs/signatures/branches IN THE CELL — they go in
the Sketch). Resolve each OQ-xxx once in §1; do not restate in §6/§8.

**Per-task Sketch (the no-placeholder rule).** After each phase's table, add one `**T-xxx sketch:**` fenced
block per *behavior* task — the pseudocode / key signature / control-flow / data shape that makes the task
implementable without guessing. NO placeholders ("add error handling", "TBD", "implement logic") — write the
real shape. A migration / config / pure-wiring task needs no sketch. **Right-size:** `full` tier → sketch
every behavior task; `small`/`bugfix`/`refactor` → sketch ONLY tasks whose control flow is non-obvious.

**Layout — group rows under interleaved `### Phase N` headings, one mini-table per phase. Do NOT use one
combined table with a trailing phase list.** `check-disjoint` and the main thread read each task's phase from
the `### Phase N` heading ABOVE it; a trailing list collapses every task into a single phase and defeats
per-phase parallel dispatch. Phases run in order (the sequential spine); the main thread fans out the `[P]`
tasks **within** each phase.

### Phase 0 — setup & migrations  _(sequential)_
| ID | Goal (imperative) | Files | Test first | Minimal change | Verify | Depends on | Req |
|----|-------------------|-------|------------|----------------|--------|------------|-----|
| T-001 | Flyway migration … | db/migration/V2__add_x.sql | — _(migration)_ | forward-only DDL | `./gradlew flywayValidate` | — | FR-001 |

### Phase 1 — domain / service  _([P] within phase — mark EVERY independent task)_
| ID | Goal | Files | Test first | Minimal change | Verify | Depends on | Req |
|----|------|-------|------------|----------------|--------|------------|-----|
| T-002 [P] | Rate-limit filter | src/…/RateLimitFilter.java, src/test/…/RateLimitFilterTest.java | RateLimitFilterTest#blocksOverLimit | reject over-limit before chain | `./gradlew test --tests RateLimitFilterTest` | T-001 | FR-002 |
| T-003 [P] | Bar service | src/…/BarService.java, src/test/…/BarServiceTest.java | BarServiceTest#y | minimal pass | `./gradlew test --tests BarServiceTest` | T-001 | FR-003 |

**T-002 sketch:**
```
class RateLimitFilter implements jakarta.servlet.Filter:   # reuse: servlet Filter, NOT a new interface
  deps: RateLimiter limiter   # Resilience4j (reuse-scan §framework) — do NOT hand-roll a token bucket
  doFilter(req, res, chain):
    key = clientKey(req)                # X-Forwarded-For header, else req.remoteAddr
    if not limiter.acquirePermission(key):
      res.status = 429; res.header("Retry-After", window); return
    chain.doFilter(req, res)
```
> reuse note: adopts Resilience4j `RateLimiter` per reuse-scan (decision: framework) — no custom limiter.

### Phase 2 — API / controller  _(after phase 1)_
| ID | Goal | Files | Test first | Minimal change | Verify | Depends on | Req |
|----|------|-------|------------|----------------|--------|------------|-----|
| T-004 | Foo endpoint | src/…/FooController.java | FooControllerIT#z | minimal pass | `./gradlew test --tests FooControllerIT` | T-002, T-003 | FR-004 |

### Phase 3 — cross-cutting  _(after phase 2)_
metrics/logging, caching, security constraints — may edit files created earlier. That is safe: a file reused
across *different* phases never runs concurrently, so it is not a parallel overlap.

## 5. Execution Order
Dependency summary (what blocks what) + which [P] tasks can run concurrently.

## 6. Risks & Mitigations
Each: risk → likelihood × impact → mitigation.

## 7. Rollback
- Migration: down-script / forward-fix strategy.
- Code: revert PR or feature-flag flip.

## 8. Done Definition
All T-xxx verify commands green · spec acceptance criteria (AC-xxx) pass · NFR deltas hold ·
spec §9 Confirmation done · every reuse anchor in §3 honored (no hand-roll where the scan said framework/adopt) ·
Review (claudehut:review) reports zero outstanding.
```
