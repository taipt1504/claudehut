# DLT + Retry Topic Pattern

## Table of contents

- [Why DLT](#why-dlt)
- [Retry-topic vs in-place retry](#retry-topic-vs-in-place-retry)
- [Standard Spring Kafka DLT pattern](#standard-spring-kafka-dlt-pattern)
- [Topic naming convention](#topic-naming-convention)
- [DLT consumer](#dlt-consumer)
- [Anti-patterns](#anti-patterns)

## Why DLT

When a message processing fails non-recoverably (bad schema, business rule violation, missing referenced data), retrying forever is wrong:
- Consumer lag grows (consumer stuck on poison message).
- DLT (Dead-Letter Topic) parks the message for human / async review.
- Healthy traffic resumes processing.

## Retry-topic vs in-place retry

| Pattern | Latency | Throughput | Use when |
|---------|---------|------------|----------|
| **In-place retry** (`FixedBackOff(2000, 3)`) | Blocks 6s on failure | Lower (thread stalled) | Transient failure expected to clear in seconds |
| **Retry-topic chain** (separate topics with delay) | Async (per topic delay) | High (main consumer free) | Backoff > 30s OR many retries |

Default for most services: **in-place 3 retries + DLT**. Switch to retry-topic when SLA matters.

## Standard Spring Kafka DLT pattern

### Container error handler

```java
@Bean
public ConcurrentKafkaListenerContainerFactory<String, OrderEvent>
        kafkaListenerContainerFactory(
            ConsumerFactory<String, OrderEvent> cf,
            KafkaTemplate<String, OrderEvent> template) {

    var factory = new ConcurrentKafkaListenerContainerFactory<String, OrderEvent>();
    factory.setConsumerFactory(cf);

    // DLT publisher: appends ".DLT" suffix to topic name by default
    var recoverer = new DeadLetterPublishingRecoverer(template,
        (record, ex) -> new TopicPartition(record.topic() + ".DLT", record.partition()));

    var handler = new DefaultErrorHandler(
        recoverer,
        new ExponentialBackOff(1000L, 2.0) {{ setMaxInterval(30_000L); }});

    // Don't retry these
    handler.addNotRetryableExceptions(
        IllegalArgumentException.class,
        DeserializationException.class,
        ValidationException.class);

    factory.setCommonErrorHandler(handler);
    return factory;
}
```

### Behavior

1. Listener throws exception.
2. ErrorHandler retries per backoff (3 attempts, exponential).
3. After retries exhausted → publish to `<topic>.DLT` via `DeadLetterPublishingRecoverer`.
4. Original record headers preserved + DLT headers added:
   - `kafka_dlt-exception-fqcn`
   - `kafka_dlt-exception-message`
   - `kafka_dlt-exception-stacktrace`
   - `kafka_dlt-original-topic`
   - `kafka_dlt-original-partition`
   - `kafka_dlt-original-offset`

### Per-message acknowledge

When handler routes to DLT, message considered processed → consumer commits offset → no infinite redelivery.

## Topic naming convention

| Topic | Purpose |
|-------|---------|
| `order.created` | Main topic |
| `order.created.DLT` | Dead letter (auto-created by `DeadLetterPublishingRecoverer`) |
| `order.created.retry.0` | Optional retry topic — 1s delay |
| `order.created.retry.1` | Optional retry topic — 30s delay |
| `order.created.retry.2` | Optional retry topic — 5m delay |

## DLT consumer

DLT messages need handling — usually a separate small consumer for alerting + manual review:

```java
@KafkaListener(topics = "order.created.DLT", groupId = "alerting-svc")
public void onDltMessage(ConsumerRecord<String, byte[]> record) {
    String origTopic = new String(
        record.headers().lastHeader("kafka_dlt-original-topic").value());
    String exceptionFqcn = new String(
        record.headers().lastHeader("kafka_dlt-exception-fqcn").value());
    String message = new String(
        record.headers().lastHeader("kafka_dlt-exception-message").value());

    alertingClient.send(AlertSeverity.HIGH,
        String.format("DLT: %s caused by %s: %s", origTopic, exceptionFqcn, message));

    // Optional: store full payload in S3 for later replay
    dltStore.archive(record);
}
```

## Anti-patterns

- No DLT configured — poison message blocks consumer forever.
- DLT but no DLT consumer → messages pile up unnoticed.
- `addRetryableExceptions(Exception.class)` — retries everything, including bad schema.
- Forgetting `addNotRetryableExceptions` for validation errors → wasted retries on guaranteed failures.
- DLT topic same partition count as source → forces single-consumer alerting.
- Manual produce to DLT instead of `DeadLetterPublishingRecoverer` → loses standard headers.
- Re-consuming DLT into main topic via manual replay without fixing root cause → loop.
