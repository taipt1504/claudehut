---
description: Show the ClaudeHut learning scoreboard — measured memory health (store size, reinforcement, effectiveness/recurrence, quality) so you can tell whether the agent is actually getting smarter across sessions. One-shot, read-only.
---

Run the deterministic scoreboard and render its output verbatim — do NOT compute or invent any numbers
yourself (honesty boundary: every figure must come from the store):

```
"${CLAUDE_PLUGIN_ROOT}/scripts/learning-score.sh" --top 5
```

Then add at most 2 lines of plain interpretation IF a signal stands out — e.g. "Effectiveness: N
promoted pitfalls recurred → those rules aren't sticking; consider strengthening them" or "Quality below
50% → learner is recording vague entries". No essays. If the store is empty, say so and stop.

This is read-only: it changes no state, writes no flag, and does not switch phase.
