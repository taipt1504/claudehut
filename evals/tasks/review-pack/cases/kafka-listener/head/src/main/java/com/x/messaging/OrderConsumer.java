package com.x.messaging;

import org.springframework.kafka.annotation.KafkaListener;

public class OrderConsumer {
    @KafkaListener(topics = "orders")
    public void on(String payload) {
    }
}
