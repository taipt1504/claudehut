# Kafka Consumer Anti-Patterns

## Table of contents

- [Ack + retry](#ack--retry)
- [Idempotency](#idempotency)
- [Serialization](#serialization)
- [Concurrency](#concurrency)
- [Schema evolution](#schema-evolution)
- [Observability](#observability)

## Ack + retry

| Anti-pattern | Why bad | Fix |
|--------------|---------|-----|
| `enable-auto-commit: true` in production | Crash mid-processing → silent loss | Manual ack + explicit `ack.acknowledge()` |
| Ack BEFORE processing | Defeats at-least-once | Ack after success only |
| No DLT configured | Poison message blocks consumer forever | `DeadLetterPublishingRecoverer` + handler |
| DLT but no consumer on DLT | Failures pile up unnoticed | Separate alerting consumer on `*.DLT` |
| `addRetryableExceptions(Exception.class)` | Retries everything, wastes time on guaranteed failures | `addNotRetryableExceptions(IllegalArgumentException, ValidationException, DeserializationException)` |
| `BATCH` ack mode with per-record ack | Acks whole batch on each `.acknowledge()` call | Use `RECORD` or `MANUAL_IMMEDIATE` for per-record control |

## Idempotency

| Anti-pattern | Why bad | Fix |
|--------------|---------|-----|
| No dedup at all | Duplicate side effects on rebalance | Dedup store keyed by `event.id` |
| Dedup mark AFTER processing | Race: crash between processing + mark → next arrival reprocesses | Mark BEFORE; rollback mark on failure |
| Dedup in in-process Map | Lost across pod restart | Redis SETNX or DB table |
| Dedup keyed on `Instant.now()` | Defeats purpose; every call unique | Key on event ID from payload |
| No TTL on dedup mark | Unbounded Redis growth | 7-day TTL covers DLT replay window |
| Catching ALL `DataIntegrityViolationException` as duplicate | Masks real DB issues | Check error code/SQL state for duplicate-key specifically |

## Serialization

| Anti-pattern | Why bad | Fix |
|--------------|---------|-----|
| `JsonSerializer` without explicit type mapping | Class FQCN in headers → consumer crash on rename | Pin types via `spring.json.type.mapping` |
| `JsonSerializer` with default typing | RCE history (Jackson CVE) | Disable; whitelist subtypes |
| Different DTO class between producer + consumer (no schema registry) | Field rename breaks consumer | Use Avro + Schema Registry OR exact same DTO |
| No `DeserializationException` handler | One bad message crashes consumer thread | `ErrorHandlingDeserializer` wrapping + DLT route |

## Concurrency

| Anti-pattern | Why bad | Fix |
|--------------|---------|-----|
| `concurrency: 1` on high-throughput topic | Single thread bottleneck | Match partition count (`concurrency: N`) |
| `concurrency: 32` on 4-partition topic | 28 threads idle | `concurrency ≤ partitions` |
| Long blocking call inside listener (WebFlux app) | Blocks event loop thread | Use `blockingExecutor` scheduler OR `Mono.fromCallable + boundedElastic` |
| Shared mutable state across concurrent listeners | Race conditions | Per-listener state; or use stateless handler |
| `@Transactional` with default propagation across listener + downstream HTTP call | Long-held DB transaction | Restructure: complete DB tx, then publish next event |

## Schema evolution

| Anti-pattern | Why bad | Fix |
|--------------|---------|-----|
| Producer adds required field; consumer not updated | Consumer fails on new messages | Make new fields optional with default until consumer rolled |
| Producer renames field | Consumer can't map old name | Expand-contract: add new alongside old, deploy, remove old later |
| Removing event type from producer before consumer drops subscription | Consumer waits forever | Deprecate first, monitor consumption, then remove |

## Observability

| Anti-pattern | Why bad | Fix |
|--------------|---------|-----|
| No metric on consumer lag | Late detection of stuck consumer | Micrometer `kafka.consumer.fetch-manager-metrics` + Prometheus alert on `records-lag-max` |
| No correlation ID propagation | Cannot trace event → request | Inject `traceparent` header on producer; extract on consumer |
| Logging full payload at INFO | Log spam + PII risk | Log only `event.id` + `event.type` at INFO; full payload at DEBUG with sampling |
| No alert on DLT publish | Silent failure accumulation | Alert per DLT message OR rolling count threshold |
