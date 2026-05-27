---
name: kafka-consumer
description: Spring Kafka consumer conventions — @KafkaListener, manual ack modes, DLT pattern, retry topic, idempotency via dedup store, JSON/Avro deserialization. Auto-loads when editing `**/*Listener*.java`, `**/*Consumer*.java` in projects with messaging=kafka.
---

# Kafka Consumer

## Quick start

```java
@Component
@RequiredArgsConstructor
@Slf4j
public class OrderEventListener {

    private final ShippingJobService shippingService;
    private final EventDedupStore dedupStore;

    @KafkaListener(topics = "order.created", groupId = "shipping-svc",
                   containerFactory = "kafkaListenerContainerFactory")
    public void onOrderCreated(@Payload OrderCreatedEvent event,
                                @Header(KafkaHeaders.RECEIVED_KEY) String key,
                                Acknowledgment ack) {
        try {
            if (dedupStore.alreadyProcessed(event.id())) {
                log.info("event {} already processed, skipping", event.id());
                ack.acknowledge();
                return;
            }
            shippingService.createJob(event);
            dedupStore.markProcessed(event.id());
            ack.acknowledge();
        } catch (TransientFailureException ex) {
            // don't ack; let listener retry
            throw ex;
        } catch (Exception ex) {
            log.error("non-recoverable error processing {}", event.id(), ex);
            ack.acknowledge();  // ack to prevent loop; goes to DLT via error handler
            throw ex;
        }
    }
}
```

Detailed: `references/ack-modes.md`, `references/dlt-retry-topic.md`, `references/idempotency.md`, `references/anti-patterns.md`.

## Assets

- `assets/templates/KafkaListener.java.tmpl`

## Hard rules

- ALWAYS manual ack mode (`AckMode.MANUAL_IMMEDIATE`) for at-least-once with control.
- ALWAYS implement idempotency (event ID dedup store or natural key check).
- ALWAYS configure DLT for non-recoverable failures.
- USE `groupId` per consuming service (not per instance).
- DO NOT use `@KafkaListener` on void method without ack — defaults can lose messages.

## Exit criteria

- [ ] Manual ack mode configured
- [ ] Idempotency check in handler
- [ ] DLT topic configured with retry topic before it
- [ ] Consumer concurrency tuned (`concurrency = N`)
