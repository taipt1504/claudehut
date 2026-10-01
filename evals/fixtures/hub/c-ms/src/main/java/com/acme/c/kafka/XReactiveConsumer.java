package com.acme.c.kafka;

import org.springframework.stereotype.Component;

/** reactor-kafka consumer of X events: the topic is the props field's yml key (c.reactive.consumer.topic). */
@Component
public class XReactiveConsumer {
  private final ReactiveConsumerProperties consumerProperties;

  public XReactiveConsumer(ReactiveConsumerProperties consumerProperties) {
    this.consumerProperties = consumerProperties;
  }

  public void start() {
    KafkaConfigUtil.createReceiver(consumerProperties).receive().subscribe();
  }
}
