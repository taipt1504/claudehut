package com.acme.e;

import org.springframework.kafka.annotation.KafkaListener;
import org.springframework.stereotype.Component;

@Component
public class EListeners {
  @KafkaListener(topics = "${app.link.topic}", groupId = "e-link")
  public void onLink(String payload) {}

  @KafkaListener(topics = "f.cmd.v1", groupId = "e-cmd")
  public void onCmd(String payload) {}
}
