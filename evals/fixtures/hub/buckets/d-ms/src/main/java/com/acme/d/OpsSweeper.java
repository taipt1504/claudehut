package com.acme.d;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.stereotype.Component;

/** Publishes an ops alert only when d.ops-topic is set. */
@Component
public class OpsSweeper {
  private final KafkaTemplate<String, String> kafkaTemplate;

  @Value("${d.ops-topic:}")
  private String opsTopic;

  public OpsSweeper(KafkaTemplate<String, String> kafkaTemplate) {
    this.kafkaTemplate = kafkaTemplate;
  }

  public void alert(String payload) {
    if (opsTopic == null || opsTopic.isBlank()) {
      return;
    }
    kafkaTemplate.send(opsTopic, payload);
  }
}
