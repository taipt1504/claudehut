package com.x.service;

import reactor.core.publisher.Flux;
import reactor.core.publisher.Mono;

public class OrderService {
    public Mono<Long> total(long a, long b) {
        return Mono.just(a + b);
    }

    public Flux<Long> all(java.util.List<Long> xs) {
        return Flux.fromIterable(xs);
    }
}
