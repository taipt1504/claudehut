package com.acme.d;

import org.springframework.stereotype.Component;

/** Custom outbox publisher: routes every event type to a configured topic (the topic-prefix is not used). */
@Component
public class DOutboxEventPublisher implements OutboxEventPublisher {
  private final DKafkaProperties kafkaProperties;
  private final GenericProducer producer;

  public DOutboxEventPublisher(DKafkaProperties kafkaProperties, GenericProducer producer) {
    this.kafkaProperties = kafkaProperties;
    this.producer = producer;
  }

  public void publish(String type, String payload) {
    producer.send(kafkaProperties.getECmdTopic(), payload);
  }
}
