package com.example.order;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class OrderController {

    private final OrderService service;

    public OrderController(OrderService service) {
        this.service = service;
    }

    // NOTE: starting point — the new endpoint is added here, currently with NO instrumentation.
    @GetMapping("/orders/{id}")
    public OrderSummary get(@PathVariable long id) {
        return service.summarize(id);
    }
}
