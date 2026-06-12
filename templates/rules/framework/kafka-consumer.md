---
id: rules/framework/kafka-consumer
paths:
  - "**/*Consumer*.java"
  - "**/*Listener*.java"
stack: "messaging=kafka"
severity: high
tags: [kafka, consumer, dlt, idempotency, rebalance, backoff]
---
<!-- ClaudeHut rule template — generated into .claude/rules/framework/kafka-consumer.md by claudehut-init. Reused & enhanced from committed rules/framework/kafka-consumer.md. -->

# Spring Kafka Consumer Rules

## DO

- Manual ack mode (`AckMode.MANUAL_IMMEDIATE`) for control.
- Idempotency check via dedup store (Redis SETNX, DB table).
- DLT configured for non-recoverable failures.
- Per-service `groupId` (not per instance).
- Tune `concurrency = N` matching partition count.
- Commit offsets and release resources in `onPartitionsRevoked`.
- Alert on consumer **lag growth rate**, not absolute lag value.

## DON'T

- Auto-ack on void method — can lose messages on failure.
- Swallow exceptions in handler.
- Block in WebFlux app's listener (use blockingExecutor scheduler).
- Forget DLT — failed messages loop forever otherwise.
- Hold long-running work without tuning `max.poll.interval.ms` — triggers rebalance storm.

## BackOff strategy decision

| Scenario | BackOff choice | Rationale |
|---|---|---|
| Transient infra (DB down, network blip) | `ExponentialBackOffWithMaxRetries(6)`, 1s→10s | Avoids hammering while broker recovers |
| Ordering-sensitive topic (finite retries, small window) | `FixedBackOff(500L, 3)` | Predictable delay; long exp. backoff stalls subsequent ordered msgs |
| Non-retryable (bad schema, NPE) | `addNotRetryableExceptions(...)` | Route straight to DLT; retrying is wasted time |

```java
ExponentialBackOffWithMaxRetries bo = new ExponentialBackOffWithMaxRetries(6);
bo.setInitialInterval(1_000L);
bo.setMultiplier(2.0);
bo.setMaxInterval(10_000L);
DefaultErrorHandler handler = new DefaultErrorHandler(
    new DeadLetterPublishingRecoverer(template), bo);
handler.addNotRetryableExceptions(IllegalArgumentException.class,
                                   DeserializationException.class);
```

## Exactly-once delivery — strategy selection

| Strategy | Use when | Constraint |
|---|---|---|
| Consumer idempotency (natural key dedup) | DB write; natural idempotent key exists | Simplest; works across any sink |
| Kafka EOS transactions (`isolation.level=read_committed`) | Read-process-write entirely within Kafka | Kafka-to-Kafka only; broker + consumer must both support transactions |
| Transactional outbox | DB write + publish must be atomic | Requires outbox table + relay; see kafka-producer rule |

Default: **consumer idempotency**. EOS only when both source and sink are Kafka topics.

## Rebalance handling

Long processing without offset commit causes `max.poll.interval.ms` expiry → broker marks consumer dead → rebalance → other consumers re-process the same messages (storm if it cascades).

**Relationship:** `max.poll.interval.ms` must exceed `max.poll.records × worst-case-record-processing-time`. Tune either down `max.poll.records` (default 500 → try 50–100) or raise the interval.

```java
@Bean
public ConcurrentKafkaListenerContainerFactory<?, ?> kafkaListenerContainerFactory(
        ConsumerFactory<String, OrderEvent> cf, KafkaTemplate<String, OrderEvent> template) {

    var factory = new ConcurrentKafkaListenerContainerFactory<String, OrderEvent>();
    factory.setConsumerFactory(cf);
    factory.getContainerProperties().setAckMode(ContainerProperties.AckMode.MANUAL_IMMEDIATE);
    factory.getContainerProperties().setConsumerRebalanceListener(
        new ConsumerAwareRebalanceListener() {
            @Override
            public void onPartitionsRevokedBeforeCommit(Consumer<?, ?> consumer,
                                                        Collection<TopicPartition> partitions) {
                // flush in-flight state, commit dedup markers
                dedupStore.flush();
            }
            @Override
            public void onPartitionsRevokedAfterCommit(Consumer<?, ?> consumer,
                                                       Collection<TopicPartition> partitions) {
                // clean up local partition caches
            }
            @Override
            public void onPartitionsAssigned(Consumer<?, ?> consumer,
                                             Collection<TopicPartition> partitions) { }
            @Override
            public void onPartitionsLost(Consumer<?, ?> consumer,
                                         Collection<TopicPartition> partitions) {
                dedupStore.flush(); // same cleanup — no commit opportunity
            }
        });

    ExponentialBackOffWithMaxRetries bo = new ExponentialBackOffWithMaxRetries(6);
    bo.setInitialInterval(1_000L);
    bo.setMultiplier(2.0);
    bo.setMaxInterval(10_000L);
    DefaultErrorHandler errorHandler = new DefaultErrorHandler(
        new DeadLetterPublishingRecoverer(template), bo);
    errorHandler.addNotRetryableExceptions(IllegalArgumentException.class);
    factory.setCommonErrorHandler(errorHandler);
    return factory;
}
```

Consumer config to pair with the above:

```yaml
spring.kafka.consumer.properties:
  max.poll.records: 100          # lower → shorter poll cycle → safer interval
  max.poll.interval.ms: 30000    # must exceed 100 × worst-record-ms; default 300000
```

## Batch listener trade-off

| | Record listener | Batch listener |
|---|---|---|
| Throughput | Moderate | High (bulk DB writes) |
| Poison-pill isolation | Automatic (record-level retry) | Manual — throw `BatchListenerFailedException(msg, record)` to identify failed record |
| Use when | Default; ordering or per-record DLT needed | High-volume sinks (e.g., bulk insert); accept added complexity |

## Lag monitoring

Alert on **lag growth** (derivative), not absolute value. A lag of 50k is fine if the consumer is catching up; a lag of 1k growing 500/min is an incident.

Prometheus query (Kafka Exporter):
```
rate(kafka_consumer_group_lag[5m]) > 100
```

## Correct example

```java
@KafkaListener(topics = "order.created", groupId = "shipping-svc",
               containerFactory = "kafkaListenerContainerFactory",
               concurrency = "4")
public void onOrderCreated(@Payload OrderEvent event,
                            @Header(KafkaHeaders.RECEIVED_KEY) String key,
                            Acknowledgment ack) {
    if (dedupStore.alreadyProcessed(event.id())) {
        ack.acknowledge();
        return;
    }
    try {
        shippingService.createJob(event);
        dedupStore.markProcessed(event.id());
        ack.acknowledge();
    } catch (TransientFailureException ex) {
        throw ex;  // listener will retry via configured BackOff
    } catch (Exception ex) {
        log.error("non-recoverable {}, to DLT", event.id(), ex);
        ack.acknowledge();
        throw ex;  // routes to DLT via error handler
    }
}
```

## Incorrect example

```java
@KafkaListener(topics = "x")  // auto-ack via default container config
public void onMessage(@Payload Message m) {
    process(m);  // exception → message lost (already auto-acked)
}
```

## References

- See `claudehut:implement` skill for ack/DLT/idempotency details and outbox + idempotent producer.
