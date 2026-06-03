---
id: rules/framework/kafka-consumer
paths:
  - "**/*Consumer*.java"
  - "**/*Listener*.java"
stack: "messaging=kafka"
severity: high
tags: [kafka, consumer, dlt, idempotency]
---
<!-- ClaudeHut rule template — generated into .claude/rules/framework/kafka-consumer.md by claudehut-init. Reused & enhanced from committed rules/framework/kafka-consumer.md. -->


# Spring Kafka Consumer Rules

## DO

- Manual ack mode (`AckMode.MANUAL_IMMEDIATE`) for control.
- Idempotency check via dedup store (Redis SETNX, DB table).
- DLT configured for non-recoverable failures.
- Per-service `groupId` (not per instance).
- Tune `concurrency = N` matching partition count.

## DON'T

- Auto-ack on void method — can lose messages on failure.
- Swallow exceptions in handler.
- Block in WebFlux app's listener (use blockingExecutor scheduler).
- Forget DLT — failed messages loop forever otherwise.

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
        throw ex;  // listener will retry
    } catch (Exception ex) {
        log.error("non-recoverable {}, to DLT", event.id(), ex);
        ack.acknowledge();
        throw ex;  // routes to DLT via error handler
    }
}
```

## Container config

```java
@Bean
public ConcurrentKafkaListenerContainerFactory<String, OrderEvent> kafkaListenerContainerFactory(
        ConsumerFactory<String, OrderEvent> cf, KafkaTemplate<String, OrderEvent> template) {

    ConcurrentKafkaListenerContainerFactory<String, OrderEvent> factory =
        new ConcurrentKafkaListenerContainerFactory<>();
    factory.setConsumerFactory(cf);
    factory.getContainerProperties().setAckMode(ContainerProperties.AckMode.MANUAL_IMMEDIATE);

    // DLT after 3 retries with exponential backoff
    DefaultErrorHandler handler = new DefaultErrorHandler(
        new DeadLetterPublishingRecoverer(template),
        new FixedBackOff(2000L, 3)
    );
    handler.addNotRetryableExceptions(IllegalArgumentException.class);
    factory.setCommonErrorHandler(handler);

    return factory;
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
