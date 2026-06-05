---
name: discover
description: Use as the FIRST phase of any non-trivial change, before brainstorming - grounds the work in the existing codebase (entry points, key types, structure) and proves whether something reusable already exists. Produces the reuse-scan artifact the write gate requires and the reuse DECISION (adopt / extend / new). Runs inline on the main thread.
allowed-tools: Read Grep Glob Bash Agent
---

# Discover (phase 1 of 7)

Ground the task in **this codebase** and settle the reuse question before any ideation. This phase was split
out of Brainstorm (decision reversal, v0.4): exploration + reuse-scan are *discovery*, not *ideation* —
folding them into Brainstorm over-fit it and killed creative breadth. Discover does the grounding; Brainstorm
(phase 2) then ideates freely on top of it. Runs **inline on the main thread** (it owns the state write; a
forked subagent cannot spawn subagents).

## Iron Law

```
NO NEW CLASS, SERVICE, UTILITY, CONFIG, OR ENDPOINT BEFORE A REUSE SCAN
```

The `PreToolUse` write gate enforces this: until `reuse_scan=true` (recorded here), every production write is
denied — in **every** complexity tier. Discover is the one phase the fast lane never skips.

## Flow

```mermaid
flowchart TB
    start([Discover phase]) --> ph["claudehut-state set-phase discover<br/>create the task dir tasks/NNNN-&lt;slug&gt;/"]
    ph --> ex["claudehut:claudehut-explorer<br/>entry points, key types, structure (cite file:line)"]
    ph --> rs["claudehut:claudehut-reuse-scanner<br/>writes tasks/NNNN-&lt;slug&gt;/reuse-scan.md (FOUND/none + DECISION)"]
    ex & rs -. "both Agent calls in ONE message (concurrent)" .-> join(( ))
    join --> rec["MAIN THREAD records set-reuse-scan --artifact …"]
    rec --> done([REQUIRED NEXT: claudehut:brainstorm])
```

## Steps

1. **Create the task dir** (every artifact of this task lives here): `NNNN` = zero-padded next integer over
   `${CLAUDE_PROJECT_DIR}/.claude/claudehut/tasks/`, slug = kebab-case task name. Record:
   `claudehut-state --session ${CLAUDE_SESSION_ID} set-phase discover`.

2. **Dispatch explorer + reuse-scanner together in ONE message** (two Agent tool calls in a single response —
   the native concurrency mechanism; their inputs are independent). **BOTH are mandatory — the scanner is not
   optional**, even when the task "obviously" has nothing to reuse (measured miss: a rate-limiting task
   skipped the scanner; the write gate then denies every production write for lack of the artifact):

   | Rationalization | Reality |
   |---|---|
   | "New infra/feature — nothing to reuse here" | Filters, configs, interceptors, utils often exist. The scan proves it either way and the gate requires the artifact. |
   | "The explorer already looked around" | Exploration ≠ a reuse DECISION with an artifact. Both run. |
   - `claudehut:claudehut-explorer` — loads the index (`PROJECT.md`, `architecture.md`, `reuse-index.json`),
     maps the packages/classes the task touches (cite `file:line`), returns entry points, key types, and a
     **Reuse candidates** list. Read-only.
   - `claudehut:claudehut-reuse-scanner` — queries `reuse-index.json` by tag, greps similar signatures/
     annotations, reads learnings tagged `reuse`, then writes
     `${CLAUDE_PROJECT_DIR}/.claude/claudehut/tasks/NNNN-<slug>/reuse-scan.md` (canonical path — the gate
     requires it under `.claude/claudehut/`) with: searched terms, **FOUND** (component + `file:line`) or
     **none**, **DECISION** (adopt / extend / new), and a justification for any new code. It **returns the
     path — it does not write state** (no Bash).

3. **Main thread records the artifact** (this flips `reuse_scan=true` and arms the gate's first precondition):

   ```
   claudehut-state --session ${CLAUDE_SESSION_ID} set-reuse-scan --artifact .claude/claudehut/tasks/NNNN-<slug>/reuse-scan.md
   ```

## Red flags — STOP

- About to write production code with no `tasks/NNNN-<slug>/reuse-scan.md` on disk.
- Treating "I read some files" as a reuse decision — the artifact with an explicit DECISION is the output.

**REQUIRED NEXT:** `claudehut:brainstorm` (it consumes this phase's context + reuse decision).
