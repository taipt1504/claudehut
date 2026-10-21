---
description: "DIAGNOSTIC (not scored with decision) — zns with the deliberate skill forced: does the loop work when it runs? N1 — the repo already sends SMS through a provider port + factory; adding ZNS (one vendor, GapOne) must follow the same pattern (rule c), not wire GapOne straight into the service."
max_turns: 40
timeout_seconds: 900
allowed_tools: [Read, Glob, Grep, Skill, Agent]
---

Use claudehut:deliberate first.

Quick one before the release: wire GapOne ZNS into notification, like PushService does for OneSignal. GapOne: POST https://api.gapone.vn/zns/send {oaId, templateId, phone, params} → {msgId}. Callers use ZnsService.send(phone, templateCode, params). GapOne is our only ZNS partner. Minimal change, compile-ready Java, no tests. Don't ask me anything.
