# JetStream Consumer

## Stream declaration (one-time, often in DevOps script)

```bash
nats stream add ORDERS \
  --subjects "orders.*" \
  --storage file \
  --retention limits \
  --max-msgs=-1 \
  --max-bytes=-1 \
  --max-age=30d \
  --discard old
```

## Push vs pull consumer

| Type | Pattern |
|------|---------|
| Push | Server delivers to subscribed queue group; auto-flow control |
| Pull | Client requests batch; fine control over rate |

For Spring services: push consumer with `Dispatcher` is simpler. Pull for high-throughput batch processing.

## Pull consumer

```java
JetStream js = nc.jetStream();
PullSubscribeOptions opts = PullSubscribeOptions.builder()
    .durable("shipping-svc")
    .build();
JetStreamSubscription sub = js.subscribe("orders.created", opts);

while (running) {
    List<Message> batch = sub.fetch(100, Duration.ofSeconds(1));
    for (Message m : batch) {
        try {
            process(m);
            m.ack();
        } catch (TransientException e) {
            m.nakWithDelay(Duration.ofSeconds(5));
        } catch (Exception e) {
            m.term();
        }
    }
}
```

## Delivery policies

| Policy | When to use |
|--------|-------------|
| `All` | Replay from start (debugging, reprocessing) |
| `Last` | Start from latest message |
| `New` | Default — only new messages from now |
| `ByStartSequence(seq)` | Resume from specific sequence |
| `ByStartTime(time)` | Resume from specific timestamp |

## Idempotency

NATS message has `seq` + `timestamp`. Use stream sequence as natural dedup key:

```java
String dedupKey = msg.metaData().streamSequence() + ":" + msg.getSubject();
if (dedupStore.alreadyProcessed(dedupKey)) {
    msg.ack();
    return;
}
process(msg);
dedupStore.markProcessed(dedupKey);
msg.ack();
```

## Flow control

For push consumers, JetStream auto-flow-controls. For pull, batch size controls rate.

## Errors

| Behavior | Method |
|----------|--------|
| Ack — processed, don't redeliver | `msg.ack()` |
| NAK — transient, redeliver per ack-wait | `msg.nak()` or `msg.nakWithDelay(...)` |
| Terminate — non-recoverable, never redeliver | `msg.term()` |
| In-progress — extend ack-wait | `msg.inProgress()` (long processing) |
