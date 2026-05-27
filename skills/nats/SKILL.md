---
name: nats
description: NATS / JetStream consumer + publisher conventions for Java (jnats). Auto-loads when editing `**/*NatsListener*.java`, `**/*NatsClient*.java` in projects with messaging=nats. Covers durable consumers, ack policies, JetStream streams + consumers, replay.
---

# NATS / JetStream

## Quick start (JetStream consumer)

```java
@Component
@RequiredArgsConstructor
@Slf4j
public class OrderEventNatsListener {

    private final Connection nc;       // jnats Connection
    private final ObjectMapper mapper;
    private final OrderService service;

    @PostConstruct
    public void start() throws Exception {
        JetStream js = nc.jetStream();
        ConsumerConfiguration cfg = ConsumerConfiguration.builder()
            .durable("shipping-svc")
            .ackPolicy(AckPolicy.Explicit)
            .deliverPolicy(DeliverPolicy.New)
            .build();
        PushSubscribeOptions opts = PushSubscribeOptions.builder()
            .stream("ORDERS")
            .configuration(cfg)
            .build();

        Dispatcher dispatcher = nc.createDispatcher(msg -> {});
        js.subscribe("orders.created", "shipping-svc-q", dispatcher, msg -> {
            try {
                OrderEvent event = mapper.readValue(msg.getData(), OrderEvent.class);
                service.handle(event);
                msg.ack();
            } catch (TransientException ex) {
                msg.nak();  // redeliver
            } catch (Exception ex) {
                log.error("non-recoverable", ex);
                msg.term();  // terminate, do not redeliver
            }
        }, true, opts);
    }
}
```

Detailed: `references/jetstream-consumer.md`, `references/durables-ack.md`.

## Assets

- `assets/templates/NatsClient.java.tmpl`

## Hard rules

- USE durable consumers (server-maintained position) for stateful processing.
- USE `AckPolicy.Explicit` for reliable processing.
- USE `nak()` for transient, `term()` for non-recoverable.
- USE JetStream (not core NATS) when persistence/replay needed.

## Exit criteria

- [ ] Durable consumer name set
- [ ] Explicit ack policy
- [ ] Transient vs non-recoverable distinction
- [ ] Stream + retention policy declared
