package com.acme.a.kafka;

import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.stereotype.Component;

/** Publishes X events. */
@Component
public class XProducer {
  private final KafkaTemplate<String, String> kafkaTemplate;

  public XProducer(KafkaTemplate<String, String> kafkaTemplate) {
    this.kafkaTemplate = kafkaTemplate;
  }

  public void publish(String key, String payload) {
    kafkaTemplate.send("x.v1", key, payload);
  }
}
