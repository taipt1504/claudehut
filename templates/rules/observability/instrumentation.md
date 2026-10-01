---
id: rules/observability/instrumentation
paths:
  - "**/*Controller.java"
  - "**/*Listener.java"
  - "**/*Consumer.java"
  - "**/*Scheduler.java"
  - "**/*Client.java"
severity: high
tags: [observability, metrics, tracing, slo, micrometer]
---
<!-- ClaudeHut rule template — generated into .claude/rules/observability/instrumentation.md by claudehut-init. -->


# Observability: metrics, tracing, SLOs

A new observable operation (HTTP endpoint, message listener, scheduled job, outbound client) is not done if
production cannot see its latency, errors, and traces. Instrumentation is a floor item, not an add-on.

## DO

- Meter every operation: Micrometer `Timer` (latency) + error `Counter`/tag, or `@Timed` / `@Observed`
  (`ObservationRegistry`). Prefer the Observation API — one call emits metric + span together.
- Use stable, low-cardinality metric names and tags (`http.server.requests`, `outcome=success|error`,
  `endpoint=/orders`). NEVER tag with a raw id, email, or free-text (cardinality explosion).
- Propagate trace context: Micrometer Tracing (or the OpenTelemetry bridge) on the classpath and wired. On the
  reactive path enable `Hooks.enableAutomaticContextPropagation()` (Boot 3.2+) so a span survives the async hop;
  otherwise bridge MDC via Reactor context.
- Back each spec NFR with an alertable meter: a p99 latency target → a `Timer` with percentile publishing; an
  error-budget target → an error-rate meter.
- On the error branch: increment an error counter/tag AND log at the correct level with context (ERROR + stack
  for unrecoverable, WARN for recoverable) per `coding/logging-mdc`.
- Publish meters through Micrometer. Actuator web exposure follows `security/actuator`: `health,info` by default;
  add `prometheus` only behind the actuator ADMIN chain or a network policy that limits it to the scraper.

## DON'T

- Ship an endpoint/listener/job with no meter — it is invisible on the dashboards and unalertable.
- Swallow an exception with neither a metric nor a log.
- Tag metrics with unbounded-cardinality values (ids, timestamps, request bodies).
- Assume the trace propagates across `Mono`/`Flux`/`@Async` without enabling context propagation — spans orphan.
- Rely on log lines alone for latency/error SLOs — logs are not a metric.

## Micrometer Observation (metric + span in one)

```java
@RestController
class OrderController {
    private final ObservationRegistry registry;

    @GetMapping("/orders/{id}/summary")
    OrderSummary summary(@PathVariable long id) {
        return Observation.createNotStarted("order.summary", registry)
            .lowCardinalityKeyValue("endpoint", "/orders/summary")
            .observe(() -> service.summarize(id));   // times, counts errors, and spans
    }
}
```

## Declarative timing

```java
@Timed(value = "payment.process", percentiles = {0.95, 0.99}, extraTags = {"channel", "card"})
public Receipt process(PaymentRequest req) { ... }
```

## Reactive trace propagation (Boot 3.2+)

```java
@PostConstruct
void enableContextPropagation() { Hooks.enableAutomaticContextPropagation(); }
```

## Anti-patterns

- A `@KafkaListener` with no timer/counter → consumer failures are silent until the DLQ fills.
- An `@Scheduled` job with no success/failure metric → a job that stops running is never noticed.
- An outbound `RestClient`/`WebClient` call with no timer → you cannot attribute latency to the dependency.
- A metric tagged `userId=<uuid>` → millions of time series, blown metrics backend.
