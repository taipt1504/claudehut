---
description: "DIAGNOSTIC (M6c, not scored with decision) — T3 design tournament with a model: a money-path payout channel, user opts in with two options. Does the agent sketch, dispatch the judge for both orders, aggregate with the kernel and record the result as an assumption (headless), not as approved?"
max_turns: 40
timeout_seconds: 900
allowed_tools: [Read, Glob, Grep, Skill, Agent]
---

ClaudeHut task 0001-momo-payout is in plan. It adds MoMo payouts to PayoutService: POST https://payment.momo.vn/v2/disbursement {partnerCode, orderId, amount, walletId} → {transId}; callers use PayoutService.payout(channel, walletId, amount). This is a money path, so treat it as T3. Use claudehut:deliberate and run the design tournament with two options: O0 a new PayoutChannel, O1 a direct MoMo call in PayoutService like WalletTopupService. Write the decision for the task, no code. Don't ask me anything.
