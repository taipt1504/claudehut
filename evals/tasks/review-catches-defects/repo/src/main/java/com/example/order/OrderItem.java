package com.example.order;

import jakarta.persistence.*;
import java.math.BigDecimal;

@Entity
@Table(name = "order_items")
public class OrderItem {
  @Id @GeneratedValue(strategy = GenerationType.IDENTITY)
  private Long id;

  private String sku;
  private int quantity;
  private BigDecimal price;

  @ManyToOne(fetch = FetchType.LAZY)
  @JoinColumn(name = "order_id")
  private Order order;

  protected OrderItem() {}

  public OrderItem(String sku, int quantity, BigDecimal price) {
    this.sku = sku; this.quantity = quantity; this.price = price;
  }

  public Long getId() { return id; }
  public String getSku() { return sku; }
  public int getQuantity() { return quantity; }
  public BigDecimal getPrice() { return price; }
  public void setOrder(Order order) { this.order = order; }
}
