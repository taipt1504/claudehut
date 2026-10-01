package com.x.controller;

@org.springframework.web.bind.annotation.RestController
public class OrderController {
    @org.springframework.security.access.prepost.PreAuthorize("hasRole('ADMIN')")
    @org.springframework.web.bind.annotation.DeleteMapping("/orders/{id}")
    public void delete(String id) {
    }
}
