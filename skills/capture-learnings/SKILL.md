---
name: capture-learnings
description: Use in the Learn phase at the end of every task, before declaring done - dispatches the learner agent to record what was learned (conventions, pitfalls, reuse points, decisions) to the cross-session store and refresh the committed memory index, then closes the phase. Runs inline on the main thread (it owns the state write).
allowed-tools: Read Grep Glob Bash Agent
---

# Capture Learnings (Learn phase)

## Iron Law

```
NO TASK ENDS WITHOUT A LEARN PASS
```

If you learned a project pattern, a pitfall, or a reuse point, record it before stopping. The `Stop` gate
blocks "done" until this runs. Runs **inline on the main thread** — the learner agent does the recording in
isolation; this skill owns the state write (the learner has no Bash).

## Process

1. **Dispatch `claudehut:claudehut-learner` (Agent tool)** with a short task summary: the task dir
   (`tasks/NNNN-<slug>/`), the decisions made, surprises hit, reuse points created, and Review findings.
   The learner:
   - Extracts candidate learnings (decisions, surprises, reuse points, review findings).
   - **Dedups** against the cross-session store at the **absolute canonical path**
     `${CLAUDE_PROJECT_DIR}/.claude/claudehut/learnings.jsonl` (NOT `.claudehut/memory.jsonl` — only the
     canonical file is injected at the next session's SessionStart): match `category` + normalized `trigger`;
     merge (`hits++`, raise `confidence`, `ts=now`) or append a new line
     (schema: `id, ts, project, phase, category, trigger, learning, evidence, confidence, hits`).
   - **Updates `reuse-index.json`** with anything newly built.
   - **Refreshes `MEMORY.md`** (the committed index) when a new topic/category/artifact appears.
   - Never records secrets or connection strings.
2. If native auto-memory is enabled, mirror a short narrative there — convenience only, not the source of truth.
3. **Main thread closes the phase** after the learner returns:

   ```
   claudehut-state --session ${CLAUDE_SESSION_ID} set-phase learn
   ```

**REQUIRED NEXT:** the task may now end (the Stop gate is satisfied). The next session's SessionStart will
inject the top of what you recorded.
