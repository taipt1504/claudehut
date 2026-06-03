---
id: rules/framework/nats
paths:
  - "**/*NatsListener*.java"
  - "**/*NatsClient*.java"
stack: "messaging=nats"
severity: high
tags: [nats, jetstream, consumer, idempotency, dlq]
---
<!-- ClaudeHut rule template — generated into .claude/rules/framework/nats.md by claudehut-init. Reused & enhanced from committed rules/framework/nats.md. -->


# NATS JetStream Consumer Rules

## DO

- Use **JetStream** (durable + at-least-once), not core NATS pub/sub, for work that must not be lost.
- Durable, named consumer (`durable(...)`) per service — survives reconnect, resumes from last ack.
- `AckPolicy.Explicit` + explicit `msg.ack()` only after the work commits.
- Idempotency via the `Nats-Msg-Id` dedup window (publisher) + a dedup store on the consumer (Redis SETNX, DB table).
- Bound redelivery with `maxDeliver(N)`; route exhausted messages to a DLQ stream/subject.
- Tune `maxAckPending` to the in-flight work the service can hold.

## DON'T

- `AckPolicy.None` / auto-ack — a crash mid-handler loses the message.
- `msg.ack()` before the side effect commits — ack then crash = silent loss.
- Block the JetStream dispatcher thread; offload blocking work to a bounded executor.
- Omit `maxDeliver` — a poison message redelivers forever, starving the consumer.
- Share one durable name across unrelated services — they steal each other's messages.

## Correct example

```java
public class OrderNatsListener {

    public void subscribe(JetStream js) throws Exception {
        PullSubscribeOptions opts = PullSubscribeOptions.builder()
            .durable("shipping-svc")                 // per-service, survives reconnect
            .configuration(ConsumerConfiguration.builder()
                .ackPolicy(AckPolicy.Explicit)
                .ackWait(Duration.ofSeconds(30))
                .maxDeliver(4)                        // then → DLQ
                .maxAckPending(256)
                .build())
            .build();
        JetStreamSubscription sub = js.subscribe("order.created", opts);

        for (Message msg : sub.fetch(50, Duration.ofSeconds(1))) {
            String id = msg.getHeaders().getFirst("Nats-Msg-Id");
            if (dedupStore.alreadyProcessed(id)) { msg.ack(); continue; }
            try {
                shippingService.createJob(msg.getData());
                dedupStore.markProcessed(id);
                msg.ack();                            // ack AFTER commit
            } catch (TransientException ex) {
                msg.nak();                            // redeliver (counts toward maxDeliver)
            } catch (Exception ex) {
                msg.term();                           // non-recoverable → stop redelivery
                deadLetter.publish("order.created.dlq", msg);
            }
        }
    }
}
```

## Stream / DLQ config

```java
// Source stream
jsm.addStream(StreamConfiguration.builder()
    .name("ORDERS").subjects("order.created")
    .retentionPolicy(RetentionPolicy.WorkQueue)
    .build());

// DLQ stream for messages that exhausted maxDeliver / were term()'d
jsm.addStream(StreamConfiguration.builder()
    .name("ORDERS_DLQ").subjects("order.created.dlq")
    .build());
```

## Incorrect example

```java
JetStreamSubscription sub = js.subscribe("order.created");  // no durable, no ack policy
Message m = sub.nextMessage(Duration.ofSeconds(1));
process(m);                                                 // crash here → message lost
// no ack, no maxDeliver, no DLQ
```

## References

- See `claudehut:implement` skill for JetStream stream/consumer setup and ack semantics.
