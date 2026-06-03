# Kafka / RabbitMQ / NATS Messaging (Spring)

<!-- Researched vs Spring Kafka 3.x (context7: /spring-projects/spring-kafka) — Spring Boot 3.2+, Java 17+ -->

**When:** `*Listener.java`, `*Consumer.java`, `*Producer.java`, `*Publisher.java`, messaging config.

---

## DO

**Kafka consumer**
- `AckMode.MANUAL_IMMEDIATE` — commit offset only after the work commits.
- Idempotency gate before processing: dedup store keyed on record key or a business ID (Redis SETNX or DB unique constraint).
- `DefaultErrorHandler` + `DeadLetterPublishingRecoverer` → `<topic>.DLT` after N retries.
- `addNotRetryableExceptions(IllegalArgumentException.class, ...)` — skip retries for poison payloads.
- `concurrency` matching partition count; one `groupId` per service (not per instance).
- `ExponentialBackOff` for transient failures; `FixedBackOff(0, 0)` only for fast-fail.

**Kafka producer**
- `enable.idempotence=true` + `acks=all` + `max.in.flight.requests.per.connection=5`.
- Explicit string key (aggregate ID) — `null` key = random partition = no ordering.
- Async send + `.whenComplete(...)` — never swallow failures, never `.get()` in a hot path.
- Transactional outbox for "DB write + publish" atomicity (Kafka tx is Kafka→Kafka only).
- `isolation.level=read_committed` on consumers that read transactional output.

**RabbitMQ** — `AcknowledgeMode.MANUAL`; `basicNack(tag, false, false)` (requeue=false) for poison → DLX; bind DLX to a durable DLQ; set `prefetchCount`.

**NATS JetStream** — durable named consumer per service; `AckPolicy.Explicit`; `maxDeliver(N)` to cap redelivery; `msg.term()` + publish to DLQ subject for non-recoverable failures.

---

## DON'T

- Auto-ack on a void handler — a crash after a side effect loses or infinitely requeues the message.
- `basicNack(tag, false, true)` (requeue=true) on a deterministic failure → hot loop forever.
- `msg.ack()` before the side effect commits — ack then crash = silent loss.
- `null` Kafka key when partition ordering matters.
- Share one NATS durable name across unrelated services — they steal each other's messages.
- DLQ transient errors (broker unavailable) — only non-retryable / poison payloads belong in the DLT.
- Mix transactional and non-transactional producers in the same `KafkaTemplate`.
- Treat a growing DLT as a resting state — alert on depth, provide a documented replay path.

---

## Correct example

```java
// ── Consumer ────────────────────────────────────────────────────────────────

@KafkaListener(topics = "order.created", groupId = "shipping-svc",
               containerFactory = "kafkaListenerContainerFactory",
               concurrency = "4")
public void onOrderCreated(@Payload OrderEvent event,
                           @Header(KafkaHeaders.RECEIVED_KEY) String key,
                           Acknowledgment ack) {
    if (dedupStore.alreadyProcessed(event.id())) { ack.acknowledge(); return; }
    try {
        shippingService.createJob(event);
        dedupStore.markProcessed(event.id());
        ack.acknowledge();                         // ack AFTER commit
    } catch (TransientFailureException ex) {
        throw ex;                                  // error handler will retry
    } catch (Exception ex) {
        log.error("non-recoverable {}, routing to DLT", event.id(), ex);
        ack.acknowledge();
        throw ex;                                  // DefaultErrorHandler → DLT
    }
}

// ── Container / error handler ────────────────────────────────────────────────

@Bean
ConcurrentKafkaListenerContainerFactory<String, OrderEvent> kafkaListenerContainerFactory(
        ConsumerFactory<String, OrderEvent> cf,
        KafkaTemplate<String, OrderEvent> template) {

    var factory = new ConcurrentKafkaListenerContainerFactory<String, OrderEvent>();
    factory.setConsumerFactory(cf);
    factory.getContainerProperties().setAckMode(ContainerProperties.AckMode.MANUAL_IMMEDIATE);

    // 3 retries, 2 s fixed backoff, then publish to order.created.DLT
    var recoverer = new DeadLetterPublishingRecoverer(template,
        (rec, ex) -> new TopicPartition(rec.topic() + ".DLT", rec.partition()));
    var handler = new DefaultErrorHandler(recoverer, new FixedBackOff(2000L, 3));
    handler.addNotRetryableExceptions(IllegalArgumentException.class);
    factory.setCommonErrorHandler(handler);
    return factory;
}

// ── Producer (idempotent, async) ─────────────────────────────────────────────

@Component
@RequiredArgsConstructor
@Slf4j
public class OrderEventPublisher {
    private static final String TOPIC = "order.created";
    private final KafkaTemplate<String, OrderEvent> kafkaTemplate;

    public CompletableFuture<SendResult<String, OrderEvent>> publish(OrderEvent event) {
        return kafkaTemplate.send(TOPIC, event.orderId(), event)   // key = aggregate ID
            .whenComplete((result, ex) -> {
                if (ex != null) log.error("publish failed: {}", event.id(), ex);
            });
    }
}
```

```yaml
# application.yml — producer
spring.kafka.producer:
  bootstrap-servers: ${KAFKA_BROKERS}
  key-serializer:   org.apache.kafka.common.serialization.StringSerializer
  value-serializer: org.springframework.kafka.support.serializer.JsonSerializer
  acks: all
  properties:
    enable.idempotence:                      true
    max.in.flight.requests.per.connection:   5
    retries:                                 2147483647
    delivery.timeout.ms:                     120000
    compression.type:                        snappy
```

**Transactional outbox** (Kafka→DB atomicity — the only safe pattern):

```java
@Transactional                          // DB transaction only
public Order createOrder(CreateOrderRequest req) {
    Order order = orderRepo.save(new Order(req));
    outboxRepo.save(new OutboxEntry(
        UUID.randomUUID(), "order.created", order.id().toString(), serialize(order)));
    return order;
}

@Scheduled(fixedDelay = 1000)           // relay: read unpublished, send, mark done
public void relayOutbox() {
    outboxRepo.findUnpublished(100).forEach(entry -> {
        try {
            kafkaTemplate.send(entry.topic(), entry.key(), entry.payload()).get(5, SECONDS);
            outboxRepo.markPublished(entry.id());
        } catch (Exception ex) { log.warn("retry next poll: {}", entry.id(), ex); }
    });
}
```

**RabbitMQ (brief):**

```java
@RabbitListener(queues = "order.created", ackMode = "MANUAL", concurrency = "4")
public void onMessage(Message msg, Channel ch,
                      @Header(AmqpHeaders.DELIVERY_TAG) long tag,
                      @Header("x-message-id") String msgId) throws IOException {
    if (dedupStore.alreadyProcessed(msgId)) { ch.basicAck(tag, false); return; }
    try {
        process(msg.getBody());
        dedupStore.markProcessed(msgId);
        ch.basicAck(tag, false);                   // ack AFTER commit
    } catch (TransientException ex) {
        ch.basicNack(tag, false, true);            // requeue: safe to retry
    } catch (Exception ex) {
        ch.basicNack(tag, false, false);           // requeue=false → DLX → DLQ
    }
}
// Queue wiring: QueueBuilder.durable("order.created")
//   .withArgument("x-dead-letter-exchange", "orders.dlx")
//   .withArgument("x-dead-letter-routing-key", "order.created.dlq").build()
```

**NATS JetStream (brief):**

```java
PullSubscribeOptions opts = PullSubscribeOptions.builder()
    .durable("shipping-svc")
    .configuration(ConsumerConfiguration.builder()
        .ackPolicy(AckPolicy.Explicit)
        .ackWait(Duration.ofSeconds(30))
        .maxDeliver(4)          // exhausted → route to DLQ subject
        .maxAckPending(256)
        .build())
    .build();
// msg.ack() AFTER commit; msg.nak() for transient; msg.term() for poison → DLQ
```

---

## Anti-pattern

```java
// Kafka — auto-ack, no key, no error handler, no DLT
@KafkaListener(topics = "order.created")
public void onMessage(@Payload OrderEvent e) {
    process(e);                      // exception → message silently lost (auto-acked)
}
kafkaTemplate.send("order.created", event);   // null key → random partition; no whenComplete

// RabbitMQ — AUTO ack, requeue=true on failure → infinite hot loop
@RabbitListener(queues = "order.created")     // default AUTO ack
public void onMessage(OrderEvent e) { process(e); }   // throws → requeued to head forever

// NATS — no durable, no explicit ack → crash = silent loss
JetStreamSubscription sub = js.subscribe("order.created");  // ephemeral, AckPolicy.None implied
process(sub.nextMessage(Duration.ofSeconds(1)));             // crash here → message gone
```

---

## Gotchas / version notes

- **Spring Kafka 3.x** removed `SeekToCurrentErrorHandler` / `RecoveringBatchErrorHandler`; use `DefaultErrorHandler` for both record and batch listeners.
- Default DLT topic = `<topic>.DLT` (same partition count); override with the `BiFunction` destination resolver.
- `DeadLetterPublishingRecoverer` requires the DLT topic to pre-exist or `auto.create.topics.enable=true`; prefer explicit topic creation in production.
- EOS (`transactional.id` + `isolation.level=read_committed`) is Kafka→Kafka only. For Kafka→DB exactly-once, use **outbox + idempotent consumer** — there is no other safe option.
- One `transactional.id` prefix per logical producer instance; stable across restarts to allow epoch fencing.
- RabbitMQ `basicNack(..., requeue=true)` on a deterministic failure (bad payload) causes a head-of-line hot loop — always use `requeue=false` for non-transient errors.
- NATS `msg.term()` stops redelivery immediately (does not count against `maxDeliver`); use it for clearly invalid/unprocessable messages.
- Monitor DLT/DLQ depth with alerts; a non-empty DLQ is a signal, not a safe bin.
