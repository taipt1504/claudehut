package com.acme.b.web;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;
import reactor.core.publisher.Mono;

/** Order endpoints of b-ms. */
@RestController
@RequestMapping("/api/v1/orders")
public class OrderController {
  @GetMapping("/{id}")
  public Mono<String> get(@PathVariable String id) {
    return Mono.just(id);
  }

  @PostMapping
  public Mono<String> create() {
    return Mono.just("ok");
  }
}
