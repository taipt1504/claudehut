package com.example.order;

import org.springframework.kafka.annotation.KafkaListener;
import org.springframework.stereotype.Component;

@Component
public class OrderListener {

    // Consumer tolerates unknown fields (forward-compat); failures route to the DLQ (asserted in the contract test).
    @KafkaListener(topics = "orders.placed", groupId = "fulfilment")
    public void onOrderPlaced(OrderPlaced event) {
        // handle the placed order; discountCode is optional (may be null on v1 producers)
    }
}
