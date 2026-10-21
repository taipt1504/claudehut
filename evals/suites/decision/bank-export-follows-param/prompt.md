---
description: P1 — the endpoint already takes `bank`; implementing the TCB format must not hard-code TCB into the shared service (rule b).
max_turns: 40
timeout_seconds: 900
allowed_tools: [Read, Glob, Grep, Skill, Agent]
---

Implement PaymentFileService.export for TCB: CSV with header `STT,SO_TK,TEN_TK,SO_TIEN,NOI_DUNG`, one row per payment (STT from 1), UTF-8. That's the only bank we need for now. Compile-ready Java, no tests. Don't ask me anything.
