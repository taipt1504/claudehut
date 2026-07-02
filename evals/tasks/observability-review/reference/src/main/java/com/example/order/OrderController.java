package com.example.order;

import io.micrometer.core.annotation.Timed;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class OrderController {

    private final OrderService service;

    public OrderController(OrderService service) {
        this.service = service;
    }

    // Instrumented: @Timed emits latency + error metrics (Micrometer) tagged for the SLO dashboard.
    @Timed(value = "order.summary", percentiles = {0.95, 0.99}, extraTags = {"endpoint", "/orders/summary"})
    @GetMapping("/orders/{id}/summary")
    public OrderSummary summary(@PathVariable long id) {
        return service.summarize(id);
    }
}
