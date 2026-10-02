package com.acme.d;

import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.stereotype.Component;

/** Sends a failed record to its dead-letter topic (<topic>.dlt). */
@Component
public class DltPublisher {
  private final KafkaTemplate<String, String> kafkaTemplate;

  public DltPublisher(KafkaTemplate<String, String> kafkaTemplate) {
    this.kafkaTemplate = kafkaTemplate;
  }

  public void publish(String sourceTopic, String payload) {
    kafkaTemplate.send(sourceTopic + ".dlt", payload);
  }
}
