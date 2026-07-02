package com.example.order;

import org.springframework.stereotype.Service;

@Service
public class OrderService {

    public OrderSummary summarize(long id) {
        // demo: fixed values; real impl would load the order
        return new OrderSummary(id, 4200L, 3);
    }
}
