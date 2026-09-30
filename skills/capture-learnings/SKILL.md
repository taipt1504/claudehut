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

If you learned a project pattern, a pitfall, or a reuse point, record it before stopping. Runs **inline on the main thread** — the learner agent does the recording in
isolation; this skill owns the state write (the learner has no Bash).

## Flow

```mermaid
flowchart TB
    start(["Learn phase entered — a fresh receipt proves the merge ran"]) --> harvest["1 HARVEST inline (no agent): harvest-candidates.sh<br/>→ learn-candidates.jsonl + harvested count"]
    harvest --> nov{"2 NOVELTY — refute 'is this NEW vs the store?'<br/>genuine new convention/pitfall/reuse/decision<br/>OR supersedes an existing L-####?"}
    nov -- "no — only confirmed existing patterns (default SKIP)" --> merge
    nov -- "yes (or harvest surfaced ≥2 candidates)" --> dispatch["dispatch claudehut-learner (sonnet)<br/>appends candidates + updates reuse-index + MEMORY.md"]
    dispatch --> merge["3 MERGE always: merge-learnings.sh<br/>dedup/quality-gate/promote/prune + write learn-receipt + .applied"]
    merge --> rcpt{"receipt written fresh THIS session<br/>AND recurred == 0?"}
    rcpt -- "recurred ≥ 1 (promoted rule re-violated)" --> surf(["escalate: SURFACE recurrence — it re-injects next session"])
    rcpt -. "no receipt / hand-appended learnings.jsonl" .-> blocked(["no receipt — re-run merge"])
    rcpt -- "yes" --> close["4-6 show scoreboard → set-phase learn → end --status done"]
    surf --> close
    close --> done(["task ended"])
```

## Process — fast path first; the agent runs only on novelty

The mandatory sonnet round-trip is inverted: a deterministic inline harvest runs first (no agent), the
learner is dispatched **only on genuine novelty**, and the merge always runs (it writes the learn receipt).

1. **Harvest candidates inline (always; no agent).** Run on the main thread:

   ```
   "${CLAUDE_PLUGIN_ROOT}/scripts/harvest-candidates.sh" --session ${CLAUDE_SESSION_ID} --task-dir .claude/claudehut/tasks/NNNN-<slug>
   ```

2. **Dispatch `claudehut:claudehut-learner` ONLY on genuine novelty — default to SKIP.** **Tier does NOT
   force it** — a full-tier task that only confirmed existing patterns records nothing new, so skip the agent
   even on full tier; when in doubt and the harvest already surfaced ≥2 candidates, dispatch. When dispatched,
   the learner **appends** to the same `learn-candidates.jsonl`, **updates `reuse-index.json`**, **refreshes
   `MEMORY.md`**, and never records secrets. It does NOT dedup, assign ids, promote, or prune.

3. **Run the deterministic merge (always — it writes the cross-session store AND the learn receipt):**

   ```
   "${CLAUDE_PLUGIN_ROOT}/scripts/merge-learnings.sh" \
     --candidates .claude/claudehut/tasks/NNNN-<slug>/learn-candidates.jsonl \
     --session ${CLAUDE_SESSION_ID} \
     --injected .claude/claudehut/state/${CLAUDE_SESSION_ID}.injected.json
   ```

   It writes `state/${SID}.learn-receipt.json` (the proof a Learn pass ran THIS task) and prints
   `{added, merged, promoted, dropped, rejected, recurred, applied}`. `recurred > 0` = a promoted rule is being
   re-violated (it re-injects next session) — surface it. Never hand-append to `learnings.jsonl`: that skips
   the receipt.
4. **Show the learning scoreboard** so memory health is visible this session (measured, not vibes):
   `"${CLAUDE_PLUGIN_ROOT}/scripts/learning-score.sh" --top 5`. Users can re-run it anytime via
   `/claudehut:claudehut-learning-report`.
5. If native auto-memory is enabled, mirror a short narrative there — convenience only, not the source of truth.
6. **Main thread closes the phase and the task** after the merge runs:

   ```
   claudehut-state --session ${CLAUDE_SESSION_ID} set-phase learn
   claudehut-state --session ${CLAUDE_SESSION_ID} end --status done
   ```

**REQUIRED NEXT:** the task has ended. The next session's SessionStart will
inject the top of what you recorded.
