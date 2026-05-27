---
name: kafka-producer
description: Spring Kafka producer conventions — idempotent producer config, transactional outbox pattern, Schema Registry integration, JSON/Avro serialization, retry + backoff. Auto-loads when editing `**/*Producer*.java`, `**/*Publisher*.java` in projects with messaging=kafka.
---

# Kafka Producer

## Quick start

```java
@Component
@RequiredArgsConstructor
@Slf4j
public class OrderEventPublisher {

    private final KafkaTemplate<String, OrderEvent> kafkaTemplate;

    public CompletableFuture<SendResult<String, OrderEvent>> publish(OrderEvent event) {
        return kafkaTemplate.send("order.created", event.orderId(), event)
            .whenComplete((result, ex) -> {
                if (ex != null) {
                    log.error("failed to publish {}", event.orderId(), ex);
                } else {
                    log.info("published {} to {}-{}@{}", event.orderId(),
                        result.getRecordMetadata().topic(),
                        result.getRecordMetadata().partition(),
                        result.getRecordMetadata().offset());
                }
            });
    }
}
```

## Idempotent producer config

```yaml
spring:
  kafka:
    producer:
      acks: all
      properties:
        enable.idempotence: true
        max.in.flight.requests.per.connection: 5
        retries: 2147483647
        delivery.timeout.ms: 120000
```

Exactly-once-per-partition with `enable.idempotence`.

## Transactional outbox

Detailed: `references/transactional-outbox.md` and `references/idempotent-producer.md`. Schema Registry: `references/schema-registry.md`.

## Assets

- `assets/templates/KafkaProducer.java.tmpl`

## Hard rules

- ALWAYS `enable.idempotence: true`.
- ALWAYS `acks: all`.
- USE transactional outbox for "publish + DB write" atomic semantics.
- USE explicit `key` (e.g., aggregate ID) for partition ordering guarantees.
- DO NOT swallow failures in `.whenComplete` — propagate or log + alert.

## Exit criteria

- [ ] Idempotent producer configured
- [ ] Explicit key per message
- [ ] Outbox pattern if "DB + publish" atomic
- [ ] Schema versioning strategy (if Avro)
