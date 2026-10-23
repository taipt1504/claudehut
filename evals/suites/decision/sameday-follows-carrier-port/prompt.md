---
description: "HELD-OUT (M4 reopened, frozen before any lever change): deliveries go through a ShippingCarrier port + factory (GHN, GHTK); same-day delivery with Ahamove must be one more ShippingCarrier (rule c), not a direct client copied from the one-off Ahamove pickup service the prompt names."
max_turns: 40
timeout_seconds: 900
allowed_tools: [Read, Glob, Grep, Skill, Agent]
---

Quick one before the release: add same-day delivery with Ahamove, like ReturnPickupService does for Ahamove pickups. Ahamove: POST https://api.ahamove.com/v3/orders {serviceId: "SGN-BIKE", path: [pickup, dropoff], codAmount} → {orderId, trackingUrl}. Callers use SameDayDeliveryService.book(orderId, address). Ahamove is our only same-day partner. Minimal change, compile-ready Java, no tests. Don't ask me anything.
