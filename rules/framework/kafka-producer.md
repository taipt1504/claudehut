---
id: rules/framework/kafka-producer
applies-to: "**/*Producer*.java, **/*Publisher*.java"
stack-signal: "messaging=kafka"
severity: high
tags: [kafka, producer, idempotent, outbox]
---

# Spring Kafka Producer Rules

## DO

- `enable.idempotence: true` + `acks: all`.
- Explicit `key` (aggregate ID) for partition ordering.
- Use transactional outbox pattern for "DB write + publish" atomicity.
- Handle async send result — `.whenComplete(...)`.
- Use Avro/Protobuf + Schema Registry for cross-team schemas.

## DON'T

- Swallow send failures.
- Use `null` key when ordering matters (random partition assignment).
- Synchronous `.get()` on send result in hot path.
- Mix transactional and non-transactional producers in same KafkaTemplate.

## Producer config (application.yml)

```yaml
spring:
  kafka:
    producer:
      bootstrap-servers: ${KAFKA_BROKERS}
      key-serializer: org.apache.kafka.common.serialization.StringSerializer
      value-serializer: org.springframework.kafka.support.serializer.JsonSerializer
      acks: all
      properties:
        enable.idempotence: true
        max.in.flight.requests.per.connection: 5
        retries: 2147483647
        delivery.timeout.ms: 120000
        compression.type: snappy
```

## Correct example

```java
@Component
@RequiredArgsConstructor
@Slf4j
public class OrderEventPublisher {

    private static final String TOPIC = "order.created";
    private final KafkaTemplate<String, OrderEvent> kafkaTemplate;

    public CompletableFuture<SendResult<String, OrderEvent>> publish(OrderEvent event) {
        return kafkaTemplate.send(TOPIC, event.orderId(), event)
            .whenComplete((result, ex) -> {
                if (ex != null) {
                    log.error("publish failed: {}", event.id(), ex);
                    // Alert + outbox retry
                }
            });
    }
}
```

## Transactional outbox

```java
@Service
@RequiredArgsConstructor
public class OrderService {
    private final OrderRepository orderRepo;
    private final OutboxRepository outboxRepo;

    @Transactional
    public Order create(CreateOrderRequest req) {
        Order order = orderRepo.save(new Order(req));
        outboxRepo.save(new OutboxEntry(
            UUID.randomUUID(), order.id().toString(), "order.created",
            order.id().toString(), serialize(order)));
        return order;
    }
}

// Separate scheduled publisher
@Scheduled(fixedDelay = 1000)
public void publishOutbox() {
    outboxRepo.findUnpublished(100).forEach(entry -> {
        try {
            kafkaTemplate.send(entry.topic(), entry.key(), entry.payload()).get(5, SECONDS);
            outboxRepo.markPublished(entry.id());
        } catch (Exception ex) {
            log.error("retry next poll", ex);
        }
    });
}
```

## Incorrect example

```java
kafkaTemplate.send("x", event);  // no key → random partition; no error handling
```

## References

- See `claudehut:kafka-producer` skill.
- Transactional outbox details: `claudehut:kafka-producer/references/transactional-outbox.md`.
