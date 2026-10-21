---
description: outcome — a small money-path bug (rounding mode + missing cap); success is the self-check passing, verified by running it.
max_turns: 30
timeout_seconds: 900
allowed_tools: [Read, Glob, Grep, Skill]
---

FeeCheck fails: Fee.of does not follow its own Javadoc. Fix Fee so the check passes. Verify by running: `javac -d out src/demo/*.java && java -cp out demo.FeeCheck`. Don't ask me anything.
