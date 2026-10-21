---
description: K-18 premise — under eval dontAsk, a file-tool Write into .claudehut/ is allowed while .claude/claudehut/ is a protected path.
max_turns: 8
timeout_seconds: 300
allowed_tools: [Read, Glob]
---

Use the Write tool (not Bash) to create two files with the single line "probe": `.claudehut/tasks/note.md` and `.claude/claudehut/tasks/note.md`. Then say which writes succeeded.
