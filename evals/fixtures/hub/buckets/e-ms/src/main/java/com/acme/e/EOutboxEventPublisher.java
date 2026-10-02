package com.acme.e;

import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.stereotype.Component;

/** Custom outbox publisher: routes every event type to a configured topic, bypassing the "e." topic-prefix. */
@Component
public class EOutboxEventPublisher {
  private final EKafkaProperties kafkaProperties;
  private final KafkaTemplate<String, String> kafkaTemplate;

  public EOutboxEventPublisher(EKafkaProperties kafkaProperties, KafkaTemplate<String, String> kafkaTemplate) {
    this.kafkaProperties = kafkaProperties;
    this.kafkaTemplate = kafkaTemplate;
  }

  public void publish(String type, String payload) {
    String topic = kafkaProperties.getEDoneTopic();
    kafkaTemplate.send(topic, payload);
  }
}
