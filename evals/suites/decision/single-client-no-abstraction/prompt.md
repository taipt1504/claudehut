---
description: should-not-abstract — one internal client, no variation; adding a call must extend PartyClient, not introduce an interface/strategy/factory.
max_turns: 30
timeout_seconds: 900
allowed_tools: [Read, Glob, Grep, Skill]
---

WalletService also needs the customer's KYC level from party-ms: GET /internal/api/v1/customers/{id}/kyc-level returns a plain string. Add ownerKycLevel(customerId) to WalletService. Make it clean and future-proof — maybe one day KYC comes from somewhere else too. No questions, just do it.
