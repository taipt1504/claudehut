package com.x.controller;

@org.springframework.web.bind.annotation.RestController
public class OrderController {
    @org.springframework.web.bind.annotation.GetMapping("/orders/total")
    public long total() {
        return 0L;
    }
}
