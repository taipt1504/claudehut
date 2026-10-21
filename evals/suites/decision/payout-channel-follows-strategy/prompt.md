---
description: "HELD-OUT (frozen before any run, M4): the repo pays out through a PayoutChannel strategy + router; adding MoMo payouts must be one more channel (rule c), not a direct call copied from the one-off top-up client."
max_turns: 30
timeout_seconds: 900
allowed_tools: [Read, Glob, Grep, Skill]
---

Quick one: wire MoMo payouts into PayoutService, like WalletTopupService talks to MoMo for top-ups. MoMo payout API: POST https://payment.momo.vn/v2/disbursement {partnerCode, orderId, amount, walletId} → {transId}. Callers use PayoutService.payout(channel, walletId, amount). Compile-ready Java, no tests. Don't ask me anything.
