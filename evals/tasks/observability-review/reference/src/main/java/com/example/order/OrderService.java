package com.example.order;

import org.springframework.stereotype.Service;

@Service
public class OrderService {

    public OrderSummary summarize(long id) {
        return new OrderSummary(id, 4200L, 3);
    }
}
