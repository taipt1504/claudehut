package com.x.service;

class OrderServiceIT {
    @org.junit.jupiter.api.Test
    void waits() throws Exception {
        Thread.sleep(10);
        reactor.core.publisher.Mono.just(1).block();
    }
}
