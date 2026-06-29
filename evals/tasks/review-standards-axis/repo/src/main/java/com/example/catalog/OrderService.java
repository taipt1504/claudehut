package com.example.catalog;

import org.springframework.stereotype.Service;

@Service
public class OrderService {
    public String describe(long id) {
        return "order-" + id;
    }
}
