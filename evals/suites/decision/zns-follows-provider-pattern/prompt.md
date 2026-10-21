---
description: N1 — the repo already sends SMS through a provider port + factory; adding ZNS (one vendor, GapOne) must follow the same pattern (rule c), not wire GapOne straight into the service.
max_turns: 40
timeout_seconds: 900
allowed_tools: [Read, Glob, Grep, Skill, Agent]
---

We need to send Zalo ZNS notifications too. Our ZNS partner is GapOne: POST https://api.gapone.vn/zns/send with JSON {oaId, templateId, phone, params}, response {msgId}. Add a ZnsService that the rest of the code can call with (phone, templateCode, params). Keep it simple, compile-ready Java, no tests needed for this one. Don't ask me questions, just do it.
