package com.x.service;

class OrderServiceTest {
    @org.junit.jupiter.api.Test
    void adds() {
        org.junit.jupiter.api.Assertions.assertEquals(3, new OrderService().total(1, 2));
    }
}
