package com.acme.c.kafka;

import org.springframework.kafka.annotation.KafkaListener;
import org.springframework.stereotype.Component;

/** Consumes X events from a-ms; the topic comes from a SpEL constant (not visible to the M5 extractor). */
@Component
public class XConsumer {
  static final String TOPICS = "#{'${c.x.consumer.topics:x.v1}'.split(',')}";

  @KafkaListener(topics = TOPICS, groupId = "c-ms-x")
  public void onX(String payload) {}

  @KafkaListener(topics = "${c.orphan.consumer.topics:orphan.v1}", groupId = "c-ms-orphan")
  public void onOrphan(String payload) {}
}
