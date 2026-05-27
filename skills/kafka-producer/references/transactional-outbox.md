# Transactional Outbox Pattern

## Problem

"Save order to DB AND publish event" must be atomic. Two-phase commit between DB and Kafka is impractical. Naïve approach:

```java
// BAD — not atomic
orderRepo.save(order);   // committed
kafka.send(orderEvent);  // may fail → DB has order, Kafka doesn't
```

If Kafka send fails after DB commit → divergent state.

## Solution — outbox table

1. Save the event to a DB table inside the same transaction as the business write.
2. A separate process polls the outbox and publishes to Kafka.
3. On publish success → mark outbox row published (or delete).

```sql
CREATE TABLE outbox (
    id UUID PRIMARY KEY,
    aggregate_id VARCHAR(64) NOT NULL,
    topic VARCHAR(128) NOT NULL,
    key VARCHAR(255),
    payload JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    published_at TIMESTAMPTZ
);
CREATE INDEX idx_outbox_unpublished ON outbox (created_at) WHERE published_at IS NULL;
```

## Atomic write

```java
@Service
@RequiredArgsConstructor
public class OrderService {
    private final OrderRepository orderRepo;
    private final OutboxRepository outboxRepo;
    private final ObjectMapper mapper;

    @Transactional
    public Order create(CreateOrderRequest req) {
        Order order = orderRepo.save(new Order(req));
        OrderCreatedEvent event = new OrderCreatedEvent(order.id(), order.amount(), Instant.now());
        OutboxEntry entry = new OutboxEntry(
            UUID.randomUUID(),
            order.id().toString(),
            "order.created",
            order.id().toString(),
            mapper.writeValueAsString(event),
            Instant.now()
        );
        outboxRepo.save(entry);
        return order;
    }
}
```

Both `orderRepo.save` and `outboxRepo.save` commit together (single TX).

## Publisher

```java
@Component
@RequiredArgsConstructor
@Slf4j
public class OutboxPublisher {
    private final OutboxRepository outboxRepo;
    private final KafkaTemplate<String, String> kafkaTemplate;

    @Scheduled(fixedDelay = 1000)  // poll every 1s
    public void publish() {
        List<OutboxEntry> unpublished = outboxRepo.findUnpublished(100);
        for (OutboxEntry e : unpublished) {
            try {
                kafkaTemplate.send(e.topic(), e.key(), e.payload()).get(5, TimeUnit.SECONDS);
                outboxRepo.markPublished(e.id());
            } catch (Exception ex) {
                log.error("failed to publish {}, will retry", e.id(), ex);
                // leave unpublished; next poll retries
            }
        }
    }
}
```

## Alternative — Debezium CDC

For higher throughput: Debezium reads Postgres WAL, publishes outbox rows to Kafka automatically. No polling needed.

## Cleanup

Periodically delete published outbox rows older than X days:

```sql
DELETE FROM outbox WHERE published_at IS NOT NULL AND published_at < NOW() - INTERVAL '7 days';
```

## Idempotency on consumer side

Even with outbox + idempotent producer, consumers should dedup by `event.id` because:
- Network retries may publish the same event twice.
- Re-publishing after crash may produce a duplicate.

See `claudehut:kafka-consumer` skill for dedup patterns.
