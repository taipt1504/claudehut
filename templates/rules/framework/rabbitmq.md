---
id: rules/framework/rabbitmq
paths:
  - "**/*RabbitListener*.java"
stack: "messaging=rabbitmq"
severity: high
tags: [rabbitmq, amqp, consumer, dlq, idempotency]
---
<!-- ClaudeHut rule template — generated into .claude/rules/framework/rabbitmq.md by claudehut-init. Reused & enhanced from committed rules/framework/rabbitmq.md. -->


# Spring AMQP (RabbitMQ) Consumer Rules

## DO

- Manual ack (`AcknowledgeMode.MANUAL`) — `channel.basicAck(tag, false)` only after the work commits.
- Idempotency check via dedup store (Redis SETNX, DB table) keyed on a message id header.
- Dead-letter exchange (`x-dead-letter-exchange`) bound to a DLQ for non-recoverable failures.
- `basicNack(tag, false, false)` (requeue=false) on poison messages → routes to the DLX, not back to the head.
- Set `prefetch` (`concurrency` / `prefetchCount`) to bound unacked in-flight messages.

## DON'T

- `AcknowledgeMode.AUTO` on a void handler — an exception after a side effect can lose or infinitely requeue the message.
- `basicNack(..., requeue=true)` on a deterministic failure — it requeues to the head and hot-loops forever.
- Swallow exceptions in the handler (the broker never learns the outcome).
- Block the listener thread on a slow downstream without raising `concurrency` (head-of-line stall).
- Omit the DLX — rejected messages vanish or loop instead of landing somewhere inspectable.

## Correct example

```java
public class OrderRabbitListener {

    @RabbitListener(queues = "order.created", ackMode = "MANUAL", concurrency = "4")
    public void onOrderCreated(Message message, Channel channel,
                               @Header(AmqpHeaders.DELIVERY_TAG) long tag,
                               @Header("x-message-id") String msgId) throws IOException {
        if (dedupStore.alreadyProcessed(msgId)) {
            channel.basicAck(tag, false);
            return;
        }
        try {
            shippingService.createJob(message.getBody());
            dedupStore.markProcessed(msgId);
            channel.basicAck(tag, false);                 // ack AFTER commit
        } catch (TransientException ex) {
            channel.basicNack(tag, false, true);          // requeue: safe to retry
        } catch (Exception ex) {
            channel.basicNack(tag, false, false);         // requeue=false → DLX → DLQ
        }
    }
}
```

## Queue / DLX config

```java
@Bean Queue ordersQueue() {
    return QueueBuilder.durable("order.created")
        .withArgument("x-dead-letter-exchange", "orders.dlx")
        .withArgument("x-dead-letter-routing-key", "order.created.dlq")
        .build();
}
@Bean Queue ordersDlq()        { return QueueBuilder.durable("order.created.dlq").build(); }
@Bean DirectExchange dlx()     { return new DirectExchange("orders.dlx"); }
@Bean Binding dlqBinding()     { return BindingBuilder.bind(ordersDlq()).to(dlx()).with("order.created.dlq"); }
```

## Incorrect example

```java
@RabbitListener(queues = "order.created")  // default AUTO ack
public void onMessage(OrderEvent event) {
    process(event);                        // throws → AUTO requeues to head → infinite hot loop
}                                          // no DLX, no idempotency
```

## References

- See `claudehut:implement` skill for DLX wiring, manual-ack, and retry/recoverer setup.
