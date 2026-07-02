package com.example.catalog;

import java.util.List;

import org.springframework.stereotype.Service;

@Service
public class OrderService {
    public String describe(long id) {
        return "order-" + id;
    }

    public Status parseStatus(String raw) {
        return StatusConverter.parse(raw);
    }

    public List<String> statusLabels() {
        return StatusConverter.labels();
    }
}
