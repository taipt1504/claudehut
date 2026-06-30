---
name: discover
description: Use as the FIRST phase of EVERY coding task, before brainstorming - grounds the work in the existing codebase (entry points, key types, structure) and proves whether something reusable already exists. Produces the reuse-scan artifact the write gate requires and the reuse DECISION (adopt / extend / new). Runs inline on the main thread; trivial tier uses the inline 3-grep variant. Skip ONLY for pure documentation/comment edits with zero production-code change.
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

## The decision ladder (what the scan decides)

The reuse-scan is not only "does the project already have it?" — it answers the full lazy-senior-dev ladder
for each thing the task would build, **stopping at the first rung that fits** (create-time depth:
`skills/implement/references/minimalism.md`):

```
0. need-to-exist?              → no: DROP it (YAGNI)                         drop
1. JDK / Java stdlib does it?  ┐
2. Spring / installed starter? ├ → use it, write nothing                    framework
3. already-declared dependency?┘   (check build.gradle/pom.xml's classpath)
4. existing PROJECT code?      → adopt as-is | extend it (cite file:line)    adopt | extend
5. nothing fits                → minimum new code, justified                 new
```

**The safety floor is never a rung you skip** — validation, error handling, security, transactions, and
observability are required no matter how lazy the build. Minimalism cuts complexity, never robustness.

## Flow

```mermaid
flowchart TB
    start([Discover phase]) --> ph["set-phase discover<br/>create tasks/NNNN-slug/"]
    ph --> tier{"recorded complexity tier?"}
    tier -- "trivial" --> inl["INLINE scan — ≤3 targeted Greps<br/>(no subagent dispatch floor)"]
    tier -- "small / full" --> fan["dispatch explorer + reuse-scanner<br/>in ONE message (concurrent, both mandatory)"]
    fan --> join["explorer map + reuse-scan.md returned"]
    inl --> wr["write reuse-scan.md (Summary table + DECISION)"]
    join --> grd{"artifact on disk AND<br/>every built dimension carries a DECISION?"}
    wr --> grd
    grd -- "no (missing row / no file)" --> rescan["re-scan the gap<br/>(re-grep inline / re-dispatch scanner)"]
    rescan --> grd
    grd -- "yes" --> rec["set-reuse-scan --artifact … (arms write gate)"]
    rec --> done([REQUIRED NEXT: claudehut:brainstorm])
```

## Steps

1. **Create the task dir** (every artifact of this task lives here): `NNNN` = zero-padded next integer over
   `${CLAUDE_PROJECT_DIR}/.claude/claudehut/tasks/`, slug = kebab-case task name. Record:
   `claudehut-state --session ${CLAUDE_SESSION_ID} set-phase discover`.

2. **Tier branch — how the scan runs depends on the recorded complexity tier** (the diagram's `tier` diamond):

   **`trivial` tier → INLINE DISCOVER (no subagents).** A no-logic change does not justify the ~26s
   2-subagent dispatch floor (measured, BENCH-REPORT). The main thread does the scan itself (≤3 targeted Grep
   calls — the class, its annotations/signature shape, the config prefix), writes
   `tasks/NNNN-<slug>/reuse-scan.md` following the Summary-table format of `references/reuse-scan-template.md`,
   then proceeds straight to Implement — **still invoking `claudehut:implement` first; the gate's skill rail
   applies in every tier.** Inline replaces the *dispatch*, never the *scan* — the gate still requires the file.

   **`small`/`full` tiers → dispatch explorer + reuse-scanner together in ONE message** (two Agent tool
   calls in a single response — the native concurrency mechanism; their inputs are independent). **In these
   tiers BOTH are mandatory — the scanner is not optional**, even when the task "obviously" has nothing to
   reuse (measured miss: a rate-limiting task skipped the scanner; the write gate then denies every
   production write for lack of the artifact):

   | Rationalization | Reality |
   |---|---|
   | "New infra/feature — nothing to reuse here" | Filters, configs, interceptors, utils often exist. The scan proves it either way and the gate requires the artifact. |
   | "The explorer already looked around" | Exploration ≠ a reuse DECISION with an artifact. Both run. |
   - `claudehut:claudehut-explorer` — loads the index (`PROJECT.md`, `architecture.md`, `reuse-index.json`),
     maps the packages/classes the task touches (cite `file:line`), returns a **Reuse candidates** list. Read-only.
   - `claudehut:claudehut-reuse-scanner` — writes
     `${CLAUDE_PROJECT_DIR}/.claude/claudehut/tasks/NNNN-<slug>/reuse-scan.md` (canonical path — the gate
     requires it under `.claude/claudehut/`) **in the summary-first format of
     `${CLAUDE_PLUGIN_ROOT}/skills/discover/references/reuse-scan-template.md` — name this template path in
     the dispatch prompt**. It **returns the path — it does not write state** (no Bash).

3. **Main thread records the artifact** (this flips `reuse_scan=true` and arms the gate's first precondition):

   ```
   claudehut-state --session ${CLAUDE_SESSION_ID} set-reuse-scan --artifact .claude/claudehut/tasks/NNNN-<slug>/reuse-scan.md
   ```

## Red flags — STOP

- About to write production code with no `tasks/NNNN-<slug>/reuse-scan.md` on disk.
- Treating "I read some files" as a reuse decision — the artifact with an explicit DECISION is the output.

**REQUIRED NEXT:** `claudehut:brainstorm` (it consumes this phase's context + reuse decision).
