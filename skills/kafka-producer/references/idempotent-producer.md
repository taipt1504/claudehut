# Idempotent Producer

## What it does

Producer assigns sequence number to each record per partition. Broker dedupes by `(producer-id, partition, sequence)`. Network retry → duplicate publish at broker → broker filters second copy. Exactly-once-per-partition guarantee within producer session.

## Config

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
        compression.type: snappy
```

When `enable.idempotence: true`:
- `acks` forced to `all`.
- `retries` defaults to `Integer.MAX_VALUE`.
- `max.in.flight.requests.per.connection` ≤ 5.

If you set conflicting values explicitly, broker rejects.

## When idempotent is NOT exactly-once

Idempotence guarantees:
- ✓ No duplicates at broker from network retry within session.

It does NOT guarantee:
- ✗ Exactly-once across producer restarts (use transactions for that).
- ✗ Exactly-once at consumer (consumer needs own dedup).
- ✗ Atomicity with DB write (use transactional outbox).

## Compared to transactional producer

| Feature | Idempotent | Transactional |
|---------|-----------|---------------|
| No dup from retry | ✓ | ✓ |
| Atomic multi-partition write | – | ✓ |
| Atomic with consumer offset commit | – | ✓ |
| Performance overhead | minimal | ~10-20% |

For most cases: idempotent + transactional outbox (in DB) covers needs without full Kafka transactions.

## Verify

```java
@Bean
public KafkaTemplate<String, OrderEvent> kafkaTemplate(ProducerFactory<String, OrderEvent> pf) {
    var template = new KafkaTemplate<>(pf);
    template.setObservationEnabled(true);
    return template;
}
```

Metrics to monitor (Micrometer):
- `kafka.producer.record.send.total`
- `kafka.producer.record.error.total`
- `kafka.producer.record.retry.total`
