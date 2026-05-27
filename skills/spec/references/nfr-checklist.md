# NFR Checklist

Non-functional requirements — every contract must address with concrete numbers.

## Performance

- [ ] Latency p50/p95/p99 budgets stated
- [ ] Throughput target (req/s or events/s)
- [ ] Resource budget (memory MB, CPU cores)
- [ ] Concurrent request handling (thread/connection model)

## Security

- [ ] Authentication required? (JWT? mTLS? API key?)
- [ ] Authorization (role/scope/tenant)
- [ ] Input validation (Bean Validation, custom)
- [ ] Output encoding (XSS, CSV injection)
- [ ] OWASP Top 10 categories applicable
- [ ] Secret handling (no logging, masked metrics)
- [ ] Audit logging required?

## Observability

- [ ] Structured logs (which fields? MDC keys?)
- [ ] Metrics (Micrometer name + tag set)
- [ ] Traces (span name, attributes)
- [ ] Health endpoint contribution if applicable

## Reliability

- [ ] Retry strategy (max attempts, backoff)
- [ ] Circuit breaker thresholds
- [ ] Timeout values (downstream, total request)
- [ ] Idempotency (key, dedupe store)
- [ ] DLT / dead-letter strategy for Kafka

## Reactive (WebFlux only)

- [ ] Scheduler choice (boundedElastic for blocking, parallel for CPU)
- [ ] Backpressure operator (onBackpressure*)
- [ ] No `.block()` calls in chain
- [ ] Context propagation (Reactor Context, MDC)

## Data

- [ ] Migration backward-compatibility (rolling deploy safe)
- [ ] Index requirements for new query patterns
- [ ] Data retention / TTL
- [ ] PII handling / GDPR

## Anti-adjective rule

Every entry MUST have a number or a concrete object. Reject:

- "fast" → use "p95 ≤ 200ms"
- "secure" → use "JWT required, role=USER"
- "scalable" → use "≥ 500 req/s with horizontal scale to 4 pods"
- "good logging" → use "log INFO with fields {userId, action, durationMs}"
