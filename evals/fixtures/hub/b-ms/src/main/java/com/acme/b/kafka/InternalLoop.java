package com.acme.b.kafka;

import org.springframework.kafka.annotation.KafkaListener;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.stereotype.Component;

/** Produces and consumes its own internal topic: never a cross-service edge. */
@Component
public class InternalLoop {
  private final KafkaTemplate<String, String> kafkaTemplate;

  public InternalLoop(KafkaTemplate<String, String> kafkaTemplate) {
    this.kafkaTemplate = kafkaTemplate;
  }

  public void kick(String v) {
    kafkaTemplate.send("b.internal.v1", v);
  }

  @KafkaListener(topics = "${b.internal.consumer.topics}")
  public void onInternal(String v) {}
}
