package com.acme.shop.messaging;

import org.springframework.kafka.annotation.KafkaListener;
import org.springframework.stereotype.Component;

@Component
public class OrderEventsListener {

  @KafkaListener(
      topics = {"orders.paid.v1", "${shop.kafka.refund-topic:orders.refunded.v1}"},
      groupId = "shop")
  public void onEvent(String payload) {}
}
