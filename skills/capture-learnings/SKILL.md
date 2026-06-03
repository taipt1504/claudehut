---
name: capture-learnings
description: Use in the Learn phase at the end of every task, before declaring done - records what was learned (conventions, pitfalls, reuse points, decisions) to the cross-session store so the next session starts smarter, and refreshes the committed memory index.
context: fork
agent: claudehut-learner
---

# Capture Learnings (Learn phase)

## Iron Law

```
NO TASK ENDS WITHOUT A LEARN PASS
```

If you learned a project pattern, a pitfall, or a reuse point, record it before stopping. The `Stop` gate blocks "done" until this runs.

## Process

1. Extract candidate learnings from the task (decisions, surprises, reuse points, review findings).
2. **Dedup** against the cross-session store at the **absolute canonical path**
   `${CLAUDE_PROJECT_DIR}/.claude/claudehut/learnings.jsonl` (NOT `.claudehut/memory.jsonl` — only the canonical
   file is injected at the next session's SessionStart): match `category` + normalized `trigger`. If it exists,
   merge (`hits++`, raise `confidence`, `ts=now`); else append a new line.
3. Append one JSON object per line (schema: `id, ts, project, phase, category, trigger, learning, evidence, confidence, hits`).
4. **Update `reuse-index.json`** with anything newly built.
5. **Refresh `MEMORY.md`** (the committed index) when a new topic/category/artifact appears, so the index keeps naming what's stored where (on-demand files stay reachable).
6. If native auto-memory is enabled, mirror a short narrative there — convenience only, not the source of truth.

Then close the phase:

```
claudehut-state --session ${CLAUDE_SESSION_ID} set-phase learn
```

**REQUIRED NEXT:** the task may now end (the Stop gate is satisfied). The next session's SessionStart will inject the top of what you recorded.
