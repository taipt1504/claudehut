---
id: rules/framework/outbound-resilience
paths:
  - "**/*Client.java"
  - "**/*WebClient*.java"
  - "**/*RestClient*.java"
  - "**/*Feign*.java"
severity: high
tags: [resilience, timeout, retry, circuit-breaker, outbound]
---
<!-- ClaudeHut rule template — generated into .claude/rules/framework/outbound-resilience.md by claudehut-init. -->

# Outbound Call Resilience Rule

Every outbound call is a dependency on someone else's availability. Without an explicit bound, one slow
downstream drains this service's threads or event loop and the failure spreads upstream.

## DO

- **Set an explicit timeout on every call.** Both connect and read/response. There is no safe default —
  `RestTemplate` and a bare `WebClient` will wait indefinitely.
- **Retry only idempotent operations**, with bounded attempts and **exponential backoff plus jitter**.
  A fixed-interval retry across many callers synchronises into a thundering herd.
- **Never retry a non-idempotent write without an idempotency key** — a timeout does not tell you whether
  the other side applied the change.
- **Circuit-break** repeated failures so a dead dependency fails fast instead of consuming the caller's
  capacity; define what the open state returns (cached value, degraded response, or an explicit error).
- **Bulkhead**: bound concurrency per dependency so one slow downstream cannot take the whole service down.
- **Propagate the trace/correlation id** on every outbound request.
- **Map failures to a domain error**, not a leaked `WebClientResponseException`/`FeignException`.

## DON'T

- `.block()` on a reactive client inside a reactive chain — see `framework/webflux`.
- Retry on `4xx` — the request is wrong; retrying cannot fix it. Retry on connect failures, `5xx`
  and timeouts only.
- Wrap the whole call in a bare `catch (Exception e) { return null; }` — a null downstream result becomes
  a `NullPointerException` far from the cause.
- Configure timeouts as literals in Java — externalise them (`@ConfigurationProperties`), so they are
  tunable per environment.

## Enforcement

- A new client class without a configured timeout is an incomplete change.
- The test suite must cover the timeout and the failure path, not only the happy path — a fake or
  WireMock stub with an injected delay.
