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
One row per task. Every behavior task names its failing test FIRST (Iron Law). [P] = no intra-phase
dependency, safe to parallelize.

| ID | Goal (imperative) | Files | Test first | Minimal change | Verify | Depends on | Req |
|----|-------------------|-------|------------|----------------|--------|------------|-----|
| T-001 | <one sentence> | src/…, test/… | <TestClass#method> | <what makes it pass — nothing else> | `./gradlew test --tests <TestClass>` | — | FR-001 |
| T-002 [P] | … | … | … | … | … | T-001 | FR-002 |

Group rows by phase when the task is big enough to need it:
- **Phase 0 — setup & migrations** (sequential): Flyway scripts, dependencies, scaffolding.
- **Phase 1 — domain/service** ([P] within phase): entities, repositories, services — unit-tested.
- **Phase 2 — API/controller** (after phase 1): controllers, DTOs, error mapping — integration-tested.
- **Phase 3 — cross-cutting** (after phase 2): metrics/logging, caching, security constraints.

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
