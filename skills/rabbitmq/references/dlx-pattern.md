# RabbitMQ DLX (Dead-Letter Exchange) Pattern

## Why DLX

When a message is rejected (NACK without requeue), TTL'd, or queue is full, RabbitMQ routes it to a configured DLX. Without DLX → message lost.

## Topology

```
[publisher] → orders.exchange → orders.q ──nack──→ orders.dlx → orders.dlq
                                                        ↑
                                                   monitored
```

## Declare in Spring AMQP

```java
@Bean
public Queue ordersQueue() {
    return QueueBuilder.durable("orders.q")
        .withArgument("x-dead-letter-exchange", "orders.dlx")
        .withArgument("x-dead-letter-routing-key", "orders.dead")
        .withArgument("x-message-ttl", 60000)              // optional
        .withArgument("x-max-length", 10000)               // optional
        .build();
}

@Bean
public DirectExchange ordersDlx() {
    return new DirectExchange("orders.dlx", true, false);
}

@Bean
public Queue ordersDlq() {
    return QueueBuilder.durable("orders.dlq").build();
}

@Bean
public Binding dlqBinding(Queue ordersDlq, DirectExchange ordersDlx) {
    return BindingBuilder.bind(ordersDlq).to(ordersDlx).with("orders.dead");
}
```

## Trigger DLX

In listener:

```java
@RabbitListener(queues = "orders.q", ackMode = "MANUAL")
public void onOrder(@Payload Order order, Channel ch, @Header(AmqpHeaders.DELIVERY_TAG) long tag) throws IOException {
    try {
        processOrder(order);
        ch.basicAck(tag, false);
    } catch (TransientException ex) {
        ch.basicNack(tag, false, true);   // requeue
    } catch (Exception ex) {
        ch.basicNack(tag, false, false);  // → DLX
    }
}
```

## DLQ consumer

```java
@RabbitListener(queues = "orders.dlq")
public void onDeadLetter(Message msg) {
    String origExchange = msg.getMessageProperties()
        .getXDeathHeader().get(0).get("exchange").toString();
    String cause = msg.getMessageProperties()
        .getXDeathHeader().get(0).get("reason").toString();
    log.error("DLQ message from {} ({}): {}", origExchange, cause, new String(msg.getBody()));
    alerting.send(...);
}
```

`x-death` header includes:
- `count` — how many times this message died
- `reason` — `rejected`, `expired`, or `maxlen`
- `queue`, `exchange`, `routing-keys` — origin
- `time` — when died

## Anti-patterns

- No DLX → poison message lost.
- `requeue=true` on permanent failure → infinite loop.
- DLX without DLQ → undeliverable, returned to source.
- DLQ without consumer → pile up unnoticed; configure alert + max-length.
- Treating DLQ as fixable inbox without root-cause fix → keeps filling.
