# RabbitMQ Topology

## Exchange types

| Type | Routing |
|------|---------|
| `direct` | Exact routing-key match |
| `topic` | Pattern match (`order.*`, `*.created`) |
| `fanout` | Broadcast to all bound queues |
| `headers` | Match on message headers |

## Configuration

```java
@Configuration
public class OrdersTopology {

    public static final String EXCHANGE = "orders.exchange";
    public static final String CREATED_QUEUE = "orders.created.q";
    public static final String DLX = "orders.dlx";
    public static final String DLQ = "orders.created.dlq";

    @Bean public TopicExchange ordersExchange() {
        return new TopicExchange(EXCHANGE, true, false);
    }

    @Bean public Queue createdQueue() {
        return QueueBuilder.durable(CREATED_QUEUE)
            .withArgument("x-dead-letter-exchange", DLX)
            .withArgument("x-dead-letter-routing-key", "created")
            .withArgument("x-message-ttl", 60000)  // ms
            .build();
    }

    @Bean public Binding createdBinding() {
        return BindingBuilder.bind(createdQueue()).to(ordersExchange()).with("order.created");
    }

    @Bean public DirectExchange dlx() {
        return new DirectExchange(DLX, true, false);
    }

    @Bean public Queue dlq() {
        return QueueBuilder.durable(DLQ).build();
    }

    @Bean public Binding dlqBinding() {
        return BindingBuilder.bind(dlq()).to(dlx()).with("created");
    }
}
```

## Message converter (JSON)

```java
@Bean
public Jackson2JsonMessageConverter messageConverter(ObjectMapper mapper) {
    return new Jackson2JsonMessageConverter(mapper);
}

@Bean
public RabbitTemplate rabbitTemplate(ConnectionFactory cf, Jackson2JsonMessageConverter converter) {
    var template = new RabbitTemplate(cf);
    template.setMessageConverter(converter);
    return template;
}
```

## Reliable publish

```yaml
spring:
  rabbitmq:
    publisher-confirm-type: correlated
    publisher-returns: true
    template:
      mandatory: true
```

```java
rabbitTemplate.setConfirmCallback((correlation, ack, cause) -> {
    if (!ack) log.error("publish nacked: {}", cause);
});

rabbitTemplate.setReturnsCallback(returned -> {
    log.error("unroutable message: {}", returned.getMessage());
});
```
