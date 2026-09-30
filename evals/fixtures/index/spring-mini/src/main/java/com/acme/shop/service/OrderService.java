package com.acme.shop.service;

import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.stereotype.Service;

/** Creates orders and publishes the created event. */
@Service
public class OrderService {

  private final KafkaTemplate<String, String> kafkaTemplate;

  public OrderService(KafkaTemplate<String, String> kafkaTemplate) {
    this.kafkaTemplate = kafkaTemplate;
  }

  public String create(String body) {
    kafkaTemplate.send("orders.created.v1", body);
    return body;
  }

  public String find(String id) {
    return id;
  }

  record Draft(String id) {}
}
