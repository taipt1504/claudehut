package com.acme.d;

import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.stereotype.Component;

/** A wrapper: the topic is a parameter, its callers name it. */
@Component
public class GenericProducer {
  private final KafkaTemplate<String, String> kafkaTemplate;

  public GenericProducer(KafkaTemplate<String, String> kafkaTemplate) {
    this.kafkaTemplate = kafkaTemplate;
  }

  public void send(String topic, String payload) {
    kafkaTemplate.send(topic, payload);
  }
}
