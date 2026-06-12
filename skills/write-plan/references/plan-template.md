# Plan template (copy per task → `.claude/claudehut/tasks/NNNN-<slug>/plan.md`)

<!-- Synthesis: spec-kit plan/tasks templates (per-task ID/Files/Test-first/Verify/Depends-on/Req-ref,
     phase grouping, [P] parallel marker) · MADR Confirmation · ClaudeHut test-first Iron Law.
     The T-xxx table below is the DURABLE task breakdown — the native Claude Code task list
     (TaskCreate/TaskUpdate) is a per-session live MIRROR of it, created by the main thread on approval. -->

```markdown
# Plan: <task title>

> spec: tasks/NNNN-<slug>/spec.md · date: YYYY-MM-DD · status: draft|approved
> approval: <approved via AskUserQuestion | non-interactive run — proceeded with draft>
> REQUIRED SUB-SKILL: claudehut:implement

## 1. Decision & Approach
**Decision (from spec §9): <chosen option> — <one-line why>.**
2–3 sentences: the Spring components to add/modify, the migration strategy, how the reuse decision
(adopt/extend/new) shapes the work. The decision is restated HERE so the plan stands alone.

## 2. Technical Context
Java/Spring versions, build tool, test framework, exact build/test commands (verbatim from PROJECT.md).

## 3. Task Breakdown
One row per task. Every behavior task names its failing test FIRST (Iron Law). `[P]` = no dependency on
another task in the SAME phase and disjoint Files — safe to run as a parallel implementer. **Mark EVERY
intra-phase-independent task `[P]`, not just one** — the main thread fans out exactly the `[P]` tasks per
phase, so under-marking serializes Implement.

**Cell budgets (hard):** `Test first` = `ClassName#method` only (≤60 chars — assertion detail lives in the
spec's AC section, not here). `Minimal change` = intent phrase ≤30 words (no FQNs, signatures, or branches —
"minimal pass" in the example rows below is the calibration, not a placeholder to expand). Whole plan ≤500
words. Resolve each OQ-xxx once in §1; do not restate in §5/§7.

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
| T-002 [P] | Foo service | src/…/FooService.java, src/test/…/FooServiceTest.java | FooServiceTest#x | minimal pass | `./gradlew test --tests FooServiceTest` | T-001 | FR-002 |
| T-003 [P] | Bar service | src/…/BarService.java, src/test/…/BarServiceTest.java | BarServiceTest#y | minimal pass | `./gradlew test --tests BarServiceTest` | T-001 | FR-003 |

### Phase 2 — API / controller  _(after phase 1)_
| ID | Goal | Files | Test first | Minimal change | Verify | Depends on | Req |
|----|------|-------|------------|----------------|--------|------------|-----|
| T-004 | Foo endpoint | src/…/FooController.java | FooControllerIT#z | minimal pass | `./gradlew test --tests FooControllerIT` | T-002, T-003 | FR-004 |

### Phase 3 — cross-cutting  _(after phase 2)_
metrics/logging, caching, security constraints — may edit files created earlier. That is safe: a file reused
across *different* phases never runs concurrently, so it is not a parallel overlap.

## 4. Execution Order
Dependency summary (what blocks what) + which [P] tasks can run concurrently.

## 5. Risks & Mitigations
Each: risk → likelihood × impact → mitigation.

## 6. Rollback
- Migration: down-script / forward-fix strategy.
- Code: revert PR or feature-flag flip.

## 7. Done Definition
All T-xxx verify commands green · spec acceptance criteria (AC-xxx) pass · NFR deltas hold ·
spec §9 Confirmation done · Review (claudehut:review) reports zero outstanding.
```
