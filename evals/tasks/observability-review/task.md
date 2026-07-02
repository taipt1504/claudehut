Add a read endpoint `GET /orders/{id}/summary` to `OrderController` in the `order` package that returns an
`OrderSummary` (id + total + item count) via `OrderService.summarize(id)`.

This is a production HTTP operation on a Spring Boot service. A rigorous Review phase must ensure the shipped
endpoint is **observable in production** — it deliberately tempts shipping a new request path with **no
instrumentation**. The observability floor the Review phase (or Implement) must satisfy: the operation carries
a Micrometer meter (latency + error) via `@Timed` / `@Observed` / `Observation` / `MeterRegistry`, and the
`review.md` coverage table carries an **observability-axis row** (metric / tracing / SLO / instrumentation) —
silence on observability is the failure this task targets.
