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

0. **Small-tier inline learn (when nothing novel surfaced).** If the tier is `small` AND the task produced
   no new pitfall, convention, or reuse point (it only confirmed existing patterns), skip the learner
   dispatch and append ONE line inline to
   `${CLAUDE_PROJECT_DIR}/.claude/claudehut/learnings.jsonl` (1 tool call — the Stop gate checks content,
   not author):

   ```json
   {"id":"<uuid>","ts":"<iso>","project":"<name>","phase":"learn","category":"convention","trigger":"<file-pattern keywords>","learning":"<one sentence: what was confirmed>","evidence":"<file:line>","confidence":0.6,"hits":1}
   ```

   Then go to step 4 (skip the learner dispatch AND the merge script — one confirmed line needs neither).
   Dispatch the full learner ONLY when something genuinely new was found — a learner round-trip to record
   "nothing new" is pure latency. (Full tier always dispatches: a task that went through Brainstorm/Spec/Plan
   has decisions worth distilling.)

1. **Dispatch `claudehut:claudehut-learner` (Agent tool)** with a short task summary: the task dir
   (`tasks/NNNN-<slug>/`), the decisions made, surprises hit, reuse points created, and Review findings.
   **Also pass this session's staged failures if present** — `.claude/claudehut/state/${CLAUDE_SESSION_ID}.failures.jsonl`
   (captured by the `PostToolUseFailure` hook). Treat it as **candidate signal, not truth**: a recurring,
   real build/dependency error is a pitfall worth recording; an intentional TDD RED test failure or a one-off
   typo is **not** — the learner filters these out.
   The learner does the **judgment** only:
   - Extracts candidate learnings (decisions, surprises, reuse points, review findings) and writes them to
     `${task_dir}/learn-candidates.jsonl` — one JSON object per line
     (`{category, trigger, learning, evidence, confidence?}`). It does **not** dedup, assign ids, promote, or
     prune (that is the script's job in step 2).
   - **Updates `reuse-index.json`** with anything newly built.
   - **Refreshes `MEMORY.md`** (the committed index) when a new topic/category/artifact appears.
   - Never records secrets or connection strings.
2. **Run the deterministic merge** on the candidates the learner produced — this is what actually writes the
   cross-session store, exactly and in milliseconds (the learner must NOT do this math by reasoning):

   ```
   "${CLAUDE_PLUGIN_ROOT}/scripts/merge-learnings.sh" --candidates "${CLAUDE_PROJECT_DIR}/.claude/claudehut/tasks/NNNN-<slug>/learn-candidates.jsonl"
   ```

   It dedups against the **canonical** `${CLAUDE_PROJECT_DIR}/.claude/claudehut/learnings.jsonl` (NOT
   `.claudehut/memory.jsonl` — only the canonical file is injected at the next session's SessionStart) by
   `category` + normalized `trigger` → merge (`hits++`, `confidence = min(+0.05, 1.0)`, `ts=now`) or append a
   new `L-####` line; **promotes** proven pitfalls (`hits≥5 ∧ confidence≥0.85`) into the matching
   `.claude/rules/` file; **prunes** decayed noise. It prints a `{added, merged, promoted, dropped}` report.
3. If native auto-memory is enabled, mirror a short narrative there — convenience only, not the source of truth.
4. **Main thread closes the phase** after the merge runs:

   ```
   claudehut-state --session ${CLAUDE_SESSION_ID} set-phase learn
   ```

**REQUIRED NEXT:** the task may now end (the Stop gate is satisfied). The next session's SessionStart will
inject the top of what you recorded.
