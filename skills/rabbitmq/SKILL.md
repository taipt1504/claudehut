---
name: rabbitmq
description: Spring AMQP (RabbitMQ) conventions — exchange/queue/binding topology, manual ack, DLX (dead-letter exchange) pattern, retry policy, message TTL. Auto-loads when editing `**/*RabbitListener*.java` in projects with messaging=rabbitmq.
---

# RabbitMQ (Spring AMQP)

## Quick start

```java
@Configuration
public class RabbitConfig {
    @Bean public Exchange ordersExchange() { return new TopicExchange("orders.exchange"); }
    @Bean public Queue ordersCreatedQueue() { return new Queue("orders.created.q", true); }
    @Bean public Binding ordersCreatedBinding(Queue q, Exchange e) {
        return BindingBuilder.bind(q).to(e).with("order.created").noargs();
    }
}

@Component
@RequiredArgsConstructor
@Slf4j
public class OrderCreatedListener {

    @RabbitListener(queues = "orders.created.q", ackMode = "MANUAL")
    public void onOrderCreated(@Payload OrderEvent event, Channel channel,
                                @Header(AmqpHeaders.DELIVERY_TAG) long tag) throws IOException {
        try {
            processEvent(event);
            channel.basicAck(tag, false);
        } catch (TransientException ex) {
            channel.basicNack(tag, false, true);  // requeue
        } catch (Exception ex) {
            log.error("non-recoverable", ex);
            channel.basicNack(tag, false, false);  // to DLX
        }
    }
}
```

Detailed: `references/topology.md`, `references/dlx-pattern.md`.

## Assets

- `assets/templates/RabbitListener.java.tmpl`

## Hard rules

- ALWAYS manual ack for control over retry/DLX.
- ALWAYS declare topology in `@Configuration` (not via management UI).
- ALWAYS configure DLX for failed messages.
- USE durable queues + persistent messages for important data.

## Exit criteria

- [ ] Topology defined in code
- [ ] Manual ack mode
- [ ] DLX configured
- [ ] Listener handles transient vs non-recoverable distinction
