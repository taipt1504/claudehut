# Consumer Idempotency

## Table of contents

- [Why idempotency](#why-idempotency)
- [Strategies](#strategies)
- [Strategy 1 — event-id dedup store](#strategy-1--event-id-dedup-store)
- [Strategy 2 — natural-key upsert](#strategy-2--natural-key-upsert)
- [Strategy 3 — DB unique constraint catch](#strategy-3--db-unique-constraint-catch)
- [Anti-patterns](#anti-patterns)

## Why idempotency

Kafka guarantees at-least-once delivery. The same event WILL arrive twice in these scenarios:
- Consumer rebalance mid-processing.
- Producer retry after broker ack timeout.
- DLT replay after fix.
- Manual re-publish during incident recovery.

If processing creates side effects (new DB row, external API call, notification), the second arrival creates a duplicate. Idempotency means "second processing is a no-op".

## Strategies

| Strategy | When |
|----------|------|
| **Event-id dedup store** (Redis SETNX, DB table) | Side effect is non-DB (notification, external API) OR DB write doesn't fit upsert |
| **Natural-key upsert** (`INSERT ... ON CONFLICT`) | Side effect is single DB row keyed by something from the event |
| **DB unique constraint catch** | Side effect is row insert; catch duplicate-key exception as "already done" |
| **Stream-table join** (Kafka Streams) | Aggregating state from many events |

## Strategy 1 — event-id dedup store

Most general. Works for any side effect.

```java
@Component
@RequiredArgsConstructor
public class EventDedupStore {
    private final StringRedisTemplate redis;

    /** Returns true if first time we see this id; false if duplicate. */
    public boolean markIfFirst(String eventId, Duration retention) {
        Boolean wasSet = redis.opsForValue()
            .setIfAbsent("dedup:" + eventId, "1", retention);
        return Boolean.TRUE.equals(wasSet);
    }
}
```

Usage:

```java
@KafkaListener(topics = "order.created")
public void onOrderCreated(@Payload OrderEvent event, Acknowledgment ack) {
    if (!dedupStore.markIfFirst(event.id(), Duration.ofDays(7))) {
        log.info("dup event {} skipped", event.id());
        ack.acknowledge();
        return;
    }
    try {
        shippingService.createJob(event);
        ack.acknowledge();
    } catch (Exception ex) {
        // Rollback dedup mark to allow retry
        dedupStore.remove(event.id());
        throw ex;
    }
}
```

### TTL guidance

- 7 days for typical event flow (covers DLT replay window).
- 30 days for low-volume critical events (manual replay).
- Match max-replay window from your incident playbook.

### Failure rollback

If processing fails AFTER `markIfFirst` returned true → must remove the mark, else legitimate retry sees "duplicate" and skips. Use try/catch as shown.

Alternative: mark AFTER processing succeeds. Risk: crash between processing + mark → second processing happens.

## Strategy 2 — natural-key upsert

Best when side effect is a single DB row.

```java
public void handle(OrderEvent event) {
    // event.id() is unique per business event
    shippingJobRepo.upsert(new ShippingJob(
        event.id(),       // PK = event id
        event.orderId(),
        event.amount()));
}
```

Postgres:

```sql
INSERT INTO shipping_jobs (id, order_id, amount, created_at)
VALUES (?, ?, ?, NOW())
ON CONFLICT (id) DO NOTHING;
```

Two arrivals → second is no-op at DB level. Most natural; no dedup store needed.

## Strategy 3 — DB unique constraint catch

```java
public void handle(OrderEvent event) {
    try {
        shippingJobRepo.save(new ShippingJob(event.id(), ...));
    } catch (DataIntegrityViolationException ex) {
        if (isDuplicateKey(ex)) {
            log.info("event {} already processed", event.id());
            return;  // treat as success
        }
        throw ex;
    }
}
```

Drawback: exception-as-control-flow. Use Strategy 2 (upsert) when possible.

## Anti-patterns

- No idempotency at all → duplicate side effects in production rebalance.
- Dedup mark AFTER processing → race window allows duplicate.
- Dedup mark without TTL → unbounded Redis growth.
- Dedup keyed on `Instant.now()` or other non-event field → defeats purpose.
- Dedup store on volatile memory (in-process Map) → forgotten across pod restart.
- Catching ALL `DataIntegrityViolationException` as "duplicate" → misses real DB issues (FK violation, NOT NULL).
- TTL too short — DLT replay after week → message reprocessed as "first time" → duplicate.
- Acking BEFORE dedup check → message gone, can't retry on real failure.

## Combining with producer idempotency

For end-to-end exactly-once-ish: producer with `enable.idempotence: true` + consumer dedup. Producer prevents duplicate publishes; consumer prevents duplicate processing. Both required — producer idempotency alone doesn't help if consumer crashes mid-processing.
