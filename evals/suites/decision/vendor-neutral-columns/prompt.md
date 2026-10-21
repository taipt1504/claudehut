---
description: N1/P3/P6 — persisting a vendor's ids must use neutral columns (provider, provider_message_id) like sms_audit, not gapone_* columns.
max_turns: 30
timeout_seconds: 900
allowed_tools: [Read, Glob, Grep, Skill]
---

Add a Flyway migration and a JPA-free record for a zns_audit table: we must keep, for each ZNS sent through GapOne, the phone, the GapOne template id, the GapOne message id and the send time. Follow the repo's conventions. No questions, just write it.
