---
description: "HELD-OUT guard (M4 reopened, frozen before any lever change): a NEW client class to our own ledger service, beside a live SMS provider family. The trigger and the write-time advisory fire, but one internal downstream needs no port: a concrete LedgerClient is right, an interface or factory is speculative."
max_turns: 30
timeout_seconds: 900
allowed_tools: [Read, Glob, Grep, Skill, Agent]
---

Add a LedgerClient for ledger-ms, our own internal service: GET http://ledger-ms/internal/api/v1/accounts/{id}/balance returns a plain decimal. WalletService.availableBalance(accountId) should use it. Quick change, compile-ready Java, no tests, no questions.
