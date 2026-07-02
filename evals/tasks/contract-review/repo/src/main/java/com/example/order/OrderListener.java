package com.example.order;

import org.springframework.kafka.annotation.KafkaListener;
import org.springframework.stereotype.Component;

@Component
public class OrderListener {

    @KafkaListener(topics = "orders.placed", groupId = "fulfilment")
    public void onOrderPlaced(OrderPlaced event) {
        // handle the placed order
    }
}
