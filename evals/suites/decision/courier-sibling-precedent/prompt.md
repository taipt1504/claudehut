---
description: "HELD-OUT (M4 reopened, frozen before any lever change; zns structure, other domain): standard deliveries go through a ShippingCarrier port + factory (GHN, GHTK) while a sibling FreightService in the same package calls its one freight vendor directly; same-day delivery with Ahamove is another delivery carrier, so it must be one more ShippingCarrier (rule c), not a copy of FreightService."
max_turns: 40
timeout_seconds: 900
allowed_tools: [Read, Glob, Grep, Skill, Agent]
---

Quick one before the release: wire Ahamove same-day delivery into order, like FreightService does for Viettel Freight. Ahamove: POST https://api.ahamove.com/v3/orders {serviceId: "SGN-BIKE", path: [pickup, dropoff], codAmount} → {orderId, trackingUrl}. Callers use SameDayService.book(orderId, address). Ahamove is our only same-day partner. Minimal change, compile-ready Java, no tests. Don't ask me anything.
