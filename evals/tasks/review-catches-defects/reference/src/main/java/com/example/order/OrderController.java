package com.example.order;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import java.math.BigDecimal;
import java.util.List;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/orders")
public class OrderController {

  private final OrderRepository orders;

  public OrderController(OrderRepository orders) {
    this.orders = orders;
  }

  // GET /orders/{id}/summary — fetch order + items in one query (fetch join, no N+1).
  @GetMapping("/{id}/summary")
  public OrderSummary summary(@PathVariable Long id) {
    Order order = orders.findWithItemsById(id).orElseThrow();
    BigDecimal total = order.getItems().stream()
        .map(i -> i.getPrice().multiply(BigDecimal.valueOf(i.getQuantity())))
        .reduce(BigDecimal.ZERO, BigDecimal::add);
    return new OrderSummary(order.getCustomer(), order.getItems().size(), total);
  }

  // POST /orders — bind a validated request DTO, not the JPA @Entity.
  @PostMapping
  public Long create(@Valid @RequestBody CreateOrderRequest request) {
    Order order = new Order(request.customer());
    request.items().forEach(i ->
        order.addItem(new OrderItem(i.sku(), i.quantity(), i.price())));
    return orders.save(order).getId();
  }

  public record CreateOrderRequest(
      @NotBlank String customer,
      @NotNull List<ItemRequest> items) {}

  public record ItemRequest(
      @NotBlank String sku,
      int quantity,
      @NotNull BigDecimal price) {}

  public record OrderSummary(String customer, int lineItems, BigDecimal total) {}
}
