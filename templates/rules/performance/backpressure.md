---
id: rules/performance/backpressure
paths:
  - "**/*Handler.java"
  - "**/*Service.java"
stack: "web=webflux"
severity: high
tags: [backpressure, webflux, reactor]
---
<!-- ClaudeHut rule template — generated into .claude/rules/performance/backpressure.md by claudehut-init. Reused & enhanced from committed rules/performance/backpressure.md. -->


# Backpressure (WebFlux)

## What is backpressure

Producer faster than consumer → buffer fills → OOM or messages dropped.

Reactor's `Flux` supports backpressure: consumer requests N items at a time; producer respects the request.

## Default Mono / Flux

`request(Long.MAX_VALUE)` by default — no backpressure.

This is fine for bounded sources (small finite collections). NOT fine for unbounded (file lines, network stream, infinite generator).

## Operators

### .limitRate(N)

Tell upstream to send at most N items at a time:

```java
Flux.fromIterable(largeList)
    .limitRate(100);   // request 100 at a time
```

### .onBackpressureBuffer(N)

Buffer up to N items; error or drop oldest beyond:

```java
Flux.create(sink -> ...)
    .onBackpressureBuffer(1000, BufferOverflowStrategy.DROP_OLDEST);
```

Strategies:
- `ERROR` — emit overflow error.
- `DROP_OLDEST` — drop earliest item.
- `DROP_LATEST` — drop newest item.

### .onBackpressureDrop()

Drop items when downstream not ready:

```java
.onBackpressureDrop(dropped -> log.warn("dropped: {}", dropped))
```

### .onBackpressureLatest()

Keep only the latest item:

```java
.onBackpressureLatest()
```

Useful for live data where only current value matters.

## When to apply

| Source | Strategy |
|--------|----------|
| Small finite collection (< 1000 items) | None needed |
| Database Flux | `.limitRate(N)` based on DB cursor size |
| Kafka consumer | already backpressure-aware via concurrent records |
| WebClient streaming response | `.limitRate(N)` |
| File reading line by line | `.limitRate(N)` |
| Sinks broadcasting events | `.onBackpressureBuffer(size, strategy)` |

## Sinks — multicast

```java
Sinks.Many<Event> sink = Sinks.many()
    .multicast()
    .onBackpressureBuffer(10_000, false);  // bounded buffer
```

Without bound → memory grows until OOM if subscribers slow.

## Detection

Phase 5 reviewer-reactive flags:

- `Flux.fromIterable` on large collection without rate limit.
- `Sinks.many().multicast()` without `onBackpressureBuffer`.
- `.buffer()` without size.
- `.window()` unbounded.
- `.cache()` on potentially infinite source.

## Anti-patterns

- Ignoring backpressure on unbounded sources → memory blowup under load.
- Excessive buffer sizes ("just to be safe") → high latency + memory waste.
- DROP strategy without metric tracking dropped count.
- Mixing rate limits across pipeline (different operators with different `limitRate`).
- Backpressure on hot Sinks without considering all subscribers' rates.

## Reactive pull pattern

```java
@GetMapping(value = "/stream", produces = MediaType.TEXT_EVENT_STREAM_VALUE)
public Flux<Event> stream() {
    return eventService.allEvents()
        .limitRate(100)                          // backpressure-aware
        .delayElements(Duration.ofMillis(10));   // throttle if needed
}
```
