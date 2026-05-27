# Contract Examples

## Example 1 — REST endpoint contract

```markdown
# User Purchase History Contract

## Acceptance criteria

### AC-1: empty list for new user
GIVEN authenticated user "u1" with no purchases
WHEN  GET /users/me/purchases?cursor=null&size=20
THEN  HTTP 200 returned
AND   body.items is empty array
AND   body.nextCursor is null

### AC-2: paginated response
GIVEN authenticated user "u1" with 50 purchases
WHEN  GET /users/me/purchases?cursor=null&size=20
THEN  HTTP 200 returned
AND   body.items has 20 elements
AND   body.nextCursor is non-null base64 string

### AC-3: unauthenticated rejected
GIVEN unauthenticated request
WHEN  GET /users/me/purchases
THEN  HTTP 401 returned
AND   body is ProblemDetail with type=urn:problem:auth-required

## API shape

POST /api/v1/users/me/purchases
Authorization: Bearer <jwt>

Response (200):
{ "items": [...], "nextCursor": "<base64>" | null, "size": 20 }

Errors:
- 401 → ProblemDetail type=urn:problem:auth-required
- 400 → ProblemDetail type=urn:problem:invalid-cursor

Java signature:
public Mono<PurchaseHistoryResponse> list(String userId, String cursor, int size);

## NFR

| NFR | Budget | Verification |
|-----|--------|--------------|
| Latency p95 | ≤ 200ms | Gatling smoke |
| Throughput | ≥ 500 req/s | Gatling load |
| Auth | JWT required | reviewer-security |
| Metric | purchase_history_requests_total{outcome} | Prometheus check |
```

## Example 2 — Kafka consumer contract

```markdown
# Order-Created → Shipping-Job Contract

## AC-1: happy path
GIVEN topic "order.created" receives valid event
WHEN  shipping consumer processes
THEN  ShippingJob row created in DB
AND   message acked
AND   metric shipping_jobs_created_total incremented

## AC-2: idempotency
GIVEN event "ord-42" already processed (in dedup store)
WHEN  same event arrives again
THEN  no new ShippingJob created
AND   message acked
AND   metric events_deduped_total incremented

## AC-3: transient failure retry
GIVEN downstream warehouse-svc returns 503
WHEN  shipping consumer attempts to call
THEN  message NOT acked
AND   retry happens 3x with 2s backoff
AND   if still failing → routed to order.created.DLT

## NFR

| NFR | Budget | Verification |
|-----|--------|--------------|
| Throughput | ≥ 600 events/s | Gatling-Kafka |
| Idempotency | dedup store key TTL 7d | unit test |
| DLT routing | within 8s of 3 retries | integration test |
```

## Example 3 — Migration contract

```markdown
# Add tenant_id to users Contract

## AC-1: rolling deploy compatibility
GIVEN existing user rows in production
WHEN  V20250527001 (nullable add) deployed
THEN  app continues to function
AND   no row-level locks > 100ms
AND   all rows backfilled by V20250528001

## AC-2: NOT NULL enforced
GIVEN V20250528001 deployed after backfill
WHEN  new user INSERT without tenant_id
THEN  constraint violation 409 returned

## Data contract

V20250527001__add_tenant_id_to_users.sql
V20250528001__set_tenant_id_not_null.sql

Backfill via OrderStatusBackfill runner (Java, batched 10k).

Backward compat: app reads tolerantly null for 24h post-deploy.
```
