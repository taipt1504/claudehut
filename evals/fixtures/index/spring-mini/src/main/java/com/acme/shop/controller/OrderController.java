package com.acme.shop.controller;

import com.acme.shop.service.OrderService;
import org.springframework.web.bind.annotation.*;

/**
 * Order HTTP API for partners. Second sentence is not the purpose.
 */
@RestController
@RequestMapping("/api/orders")
public class OrderController {

  // @Service — a comment, never a component
  private static final String NOTE = "see http://example.invalid/docs"; // not a comment start

  private final OrderService orderService;

  public OrderController(OrderService orderService) {
    this.orderService = orderService;
  }

  @GetMapping("/{id}")
  public String get(@PathVariable String id) {
    return orderService.find(id);
  }

  @PostMapping
  public String create(@RequestBody String body) {
    return orderService.create(body);
  }

  @PutMapping("/{id}")
  public String update(@PathVariable String id, @RequestBody String body) {
    return body;
  }

  @DeleteMapping("/{id}")
  public void delete(@PathVariable String id) {}

  @PatchMapping(path = "/{id}/status")
  public String patch(@PathVariable String id) {
    return id;
  }

  @RequestMapping(
      value = "/search",
      method = RequestMethod.POST)
  public String search(@RequestBody String q) {
    return q;
  }
}
