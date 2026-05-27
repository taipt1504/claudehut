# Kafka Consumer Ack Modes (Spring Kafka)

## Table of contents

- [Mode summary](#mode-summary)
- [Recommended for ClaudeHut: MANUAL_IMMEDIATE](#recommended-for-claudehut-manual_immediate)
- [Per-mode behavior](#per-mode-behavior)
- [Container config](#container-config)
- [Anti-patterns](#anti-patterns)

## Mode summary

| Mode | When commit | Trade-off |
|------|-------------|-----------|
| `RECORD` | After each record processed | Slow throughput, fine-grained recovery |
| `BATCH` | After each poll batch processed | Higher throughput; whole batch redelivers on failure |
| `TIME` | Every N ms regardless of record completion | Time-bounded duplicate window |
| `COUNT` | Every N records regardless of completion | Count-bounded duplicate window |
| `COUNT_TIME` | Whichever of TIME or COUNT triggers first | Hybrid |
| `MANUAL` | Application calls `ack.acknowledge()`; commit at next poll | Control + standard async commit |
| `MANUAL_IMMEDIATE` | Application calls `ack.acknowledge()`; commit synchronously immediately | Strongest control; slight latency cost |

## Recommended for ClaudeHut: MANUAL_IMMEDIATE

```yaml
spring:
  kafka:
    listener:
      ack-mode: MANUAL_IMMEDIATE
      concurrency: 4
    consumer:
      enable-auto-commit: false
      auto-offset-reset: earliest
      max-poll-records: 100
      isolation-level: read_committed
```

```java
@KafkaListener(topics = "order.created", groupId = "shipping-svc",
               containerFactory = "kafkaListenerContainerFactory")
public void onOrderCreated(@Payload OrderEvent event, Acknowledgment ack) {
    try {
        if (dedupStore.alreadyProcessed(event.id())) {
            ack.acknowledge();   // ack dupes too — already done
            return;
        }
        service.handle(event);
        dedupStore.markProcessed(event.id());
        ack.acknowledge();
    } catch (TransientFailureException ex) {
        // Don't ack → message redelivers after rebalance / retry
        throw ex;
    } catch (Exception ex) {
        log.error("non-recoverable {}", event.id(), ex);
        ack.acknowledge();  // ack to prevent infinite loop; goes to DLT via error handler
        throw ex;           // signals error handler to route to DLT
    }
}
```

## Per-mode behavior

### Pros/cons summary

| Mode | At-least-once | Throughput | Duplicate risk on failure |
|------|---------------|------------|---------------------------|
| RECORD | ✓ | Lowest | 0–1 record |
| BATCH | ✓ | Highest | Whole batch |
| MANUAL_IMMEDIATE | ✓ | Mid | Application-controlled |

### Why not auto-commit

`enable-auto-commit: true` commits offset on poll interval regardless of processing. A crash mid-processing → message marked done → loss. Avoid in production.

## Container config (per-service factory)

```java
@Bean
public ConcurrentKafkaListenerContainerFactory<String, OrderEvent>
        kafkaListenerContainerFactory(
            ConsumerFactory<String, OrderEvent> cf,
            KafkaTemplate<String, OrderEvent> template) {

    ConcurrentKafkaListenerContainerFactory<String, OrderEvent> factory =
        new ConcurrentKafkaListenerContainerFactory<>();
    factory.setConsumerFactory(cf);
    factory.getContainerProperties()
        .setAckMode(ContainerProperties.AckMode.MANUAL_IMMEDIATE);
    factory.setConcurrency(4);  // match partition count

    DefaultErrorHandler handler = new DefaultErrorHandler(
        new DeadLetterPublishingRecoverer(template),
        new FixedBackOff(2000L, 3));
    handler.addNotRetryableExceptions(
        IllegalArgumentException.class,
        DeserializationException.class);
    factory.setCommonErrorHandler(handler);

    return factory;
}
```

## Anti-patterns

- `enable-auto-commit: true` in production — silent data loss on crash.
- Acking BEFORE processing (`ack.acknowledge()` then `service.handle(...)`) — defeats at-least-once.
- Forgetting to ack on dedup-hit path — message stuck redelivering forever.
- Manual ack mode but `@KafkaListener` void return without `Acknowledgment` parameter — compile fine, ack never happens, container assumes ack on method return.
- Acking with `acknowledge()` on `BATCH` mode — acks the WHOLE batch, not the current record.
