# NATS JetStream Durables + Ack

## Durable consumer

Durable consumer = NATS server stores subscription position. Client can disconnect/reconnect without losing place.

```java
ConsumerConfiguration cfg = ConsumerConfiguration.builder()
    .durable("shipping-svc")               // persisted name
    .deliverPolicy(DeliverPolicy.New)
    .ackPolicy(AckPolicy.Explicit)
    .ackWait(Duration.ofSeconds(30))
    .maxDeliver(3)
    .build();
```

## Ack policies

| Policy | Behavior |
|--------|----------|
| `Explicit` | Client must call `msg.ack()` per message |
| `All` | Acking message N also acks 1..N-1 (sequential) |
| `None` | Server-driven; no ack tracking |

`Explicit` is standard for at-least-once with per-message control.

## Ack methods

| Method | Effect |
|--------|--------|
| `msg.ack()` | Processed; don't redeliver |
| `msg.nak()` | Transient fail; redeliver after `ackWait` |
| `msg.nakWithDelay(Duration)` | Redeliver after specified delay |
| `msg.term()` | Terminate; don't redeliver (permanent fail) |
| `msg.inProgress()` | Extend `ackWait` (for long processing) |

## Pattern

```java
Dispatcher dispatcher = nc.createDispatcher(msg -> {});
js.subscribe("orders.created", "shipping-q", dispatcher, msg -> {
    try {
        OrderEvent e = mapper.readValue(msg.getData(), OrderEvent.class);
        if (dedup.alreadyProcessed(e.id())) {
            msg.ack();
            return;
        }
        service.handle(e);
        msg.ack();
    } catch (TransientException ex) {
        msg.nakWithDelay(Duration.ofSeconds(5));
    } catch (Exception ex) {
        log.error("non-recoverable", ex);
        msg.term();
    }
}, true, opts);
```

## maxDeliver

After N delivery attempts (default unlimited), JetStream stops delivering. Message goes to stream's DLT-equivalent (advisory subject) or dropped per config.

Recommended: `maxDeliver: 3` + monitor `$JS.EVENT.ADVISORY.CONSUMER.MAX_DELIVERIES.<stream>.<consumer>`.

## ackWait

How long server waits for ack before redelivering. Default 30s. Set ≥ P99 of your processing time + safety margin.

For long jobs: call `msg.inProgress()` periodically to extend.

## Durable name strategy

- Per consuming service: `durable: "shipping-svc"` (not per pod).
- All pods of same service share the durable → consumer group.
- Restart-safe: server tracks last acked sequence.

## Pull vs push consumer

| Pull | Push |
|------|------|
| Client requests batch via `sub.fetch(N, timeout)` | Server pushes via callback |
| Fine-grained flow control | Easier code |
| Best for high-throughput batch | Best for low-latency event handling |

## Anti-patterns

- No durable name → ephemeral consumer; loses position on disconnect.
- `AckPolicy.None` + side effects → data loss on crash.
- `maxDeliver: unlimited` → poison message loops forever.
- Forgetting `nak()` on transient → server redelivers but at wrong time.
- Using `term()` for transient errors → permanent loss.
