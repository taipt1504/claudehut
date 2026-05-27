# Worked Examples

## Table of contents

- [Example 1 — REST endpoint (Spring MVC)](#example-1--rest-endpoint-spring-mvc)
- [Example 2 — Kafka consumer (WebFlux)](#example-2--kafka-consumer-webflux)
- [Example 3 — Flyway migration with backfill](#example-3--flyway-migration-with-backfill)

## Example 1 — REST endpoint (Spring MVC)

**User prompt:** "Add an endpoint to fetch user purchase history."

**Round 1 (Q1):** "Who calls this — the mobile app, an admin tool, or a third-party integrator? And what's the auth model?"

User: "Mobile app for the logged-in user."

**Round 2 (Q2):** "Path shape preference: `/users/me/purchases` or `/purchases?userId=me`? And paging?"

User: "First. 20 per page, cursor-based."

**Reuse-scan:** found `PurchaseRepository#findByUserId(...)` and `Pagination#cursorOf(...)`. Confirmed reuse with user.

**Round 3 (Q3):** "Latency budget — is p95 ≤ 200ms acceptable, given downstream DB?"

User: "Yes."

**Round 5 (Q5):** "Definition of done: 200 returns paginated purchases for the authenticated user; 404 if no purchases; 401 if no JWT — correct?"

User: approves.

**Design doc** then proposes: `GET /users/me/purchases?cursor=<>&size=20` → `PurchaseController.list(...)` → reuses `PurchaseRepository.findByUserId(userId, cursor, pageSize)` → returns `Page<PurchaseResponse>`. NFR: p95 ≤ 200ms. Tests: WebMvcTest slice + integration with Testcontainers.

## Example 2 — Kafka consumer (WebFlux)

**User prompt:** "Consume order-created events and create a shipping job."

**Round 1 (Q1):** "Idempotency — what if the same event arrives twice (rebalance)?"

User: "Must not create duplicate jobs."

**Round 2 (Q4):** Reuse-scan finds `EventDedupStore` (Redis-backed). Confirm reuse.

**Round 3 (Q3):** "Backpressure — what's expected event rate, and how slow can shipping-job creation be?"

User: "~500/s peak, creation ~50ms."

**Design doc** proposes: `@KafkaListener` on topic `order.created` → `OrderHandler.handle(Mono<OrderEvent>)` → `EventDedupStore.checkAndMark` → `ShippingJobService.create(...)` → ack. Manual ack mode. DLT after 3 retries. NFR: throughput ≥ 600/s with `concurrency=4`, idempotent via Redis SETNX. Tests: StepVerifier on handler, integration with Testcontainers Kafka + Redis.

## Example 3 — Flyway migration with backfill

**User prompt:** "Add `tenant_id` column to `users` table."

**Round 1 (Q1):** "Is it nullable initially, then backfilled? Or filled at INSERT time only?"

User: "Existing rows backfill from `organization.tenant_id`, new rows MUST be non-null."

**Round 2 (Q2):** "Online migration on a 50M-row table — can we afford a long lock?"

User: "No. Production traffic continuous."

**Reuse-scan:** found `MigrationBackfillJob` pattern from previous tenant column addition. Reuse.

**Design doc** proposes: 3-step migration (V20250527001 add nullable column + index `CONCURRENTLY`; V20250527002 backfill in batches of 10k via background job; V20250527003 NOT NULL constraint). Backward-compatibility: app code reads tolerantly null for 24h. Test: Testcontainers Postgres replays migration; assert no lock > 100ms via `pg_stat_activity` sampling.
