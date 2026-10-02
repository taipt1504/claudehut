package com.acme.d;

import org.springframework.kafka.annotation.KafkaListener;
import org.springframework.stereotype.Component;

@Component
public class DoneListener {
  @KafkaListener(topics = "${d.done-topic}", groupId = "d-done")
  public void onDone(String payload) {}
}
