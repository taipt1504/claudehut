# Review — order summary endpoint

| Check | Status | Evidence |
|-------|--------|----------|
| feature: GET /orders/{id}/summary | ✓ satisfied | OrderController.java:16 summary(id) |
| observability: latency+error metered | ✓ satisfied | OrderController.java:15 `@Timed("order.summary", percentiles 0.95/0.99)` (Micrometer instrumentation) |
| observability: trace propagation | ✓ n-a | synchronous servlet path — Boot auto-instruments http.server.requests span |
| observability: SLO timer for NFR | ✓ satisfied | percentile timer `order.summary` alertable on p99 |
| correctness/conventions | ✓ satisfied | OrderService.java:8 summarize(id) |

Tests: ./gradlew test — 3 passed

Verdict: pass — observability axis engaged; the new request path is metered and alertable.
