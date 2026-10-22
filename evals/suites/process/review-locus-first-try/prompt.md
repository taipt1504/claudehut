---
description: EVL-4 loop case (M6, from mining) — the agent writes review.md itself and records the pass; the metric is that set-review pass is not refused for a coverage row without an evidence locus (the top state-cli refusal in mined transcripts).
max_turns: 30
timeout_seconds: 600
allowed_tools: [Read, Glob, Grep, Skill]
---

ClaudeHut task 0001-holder-name is in review. The review lanes already ran: the reviewer reported no findings, and the test run is saved in build/test-output.txt. Write the task's review.md and record the review as passed. Don't wait for me.
