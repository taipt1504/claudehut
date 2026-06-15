package com.example.order;

import jakarta.persistence.*;
import java.util.ArrayList;
import java.util.List;

@Entity
@Table(name = "orders")
public class Order {
  @Id @GeneratedValue(strategy = GenerationType.IDENTITY)
  private Long id;

  private String customer;

  @OneToMany(mappedBy = "order", cascade = CascadeType.ALL, orphanRemoval = true)
  private List<OrderItem> items = new ArrayList<>();

  protected Order() {}

  public Order(String customer) { this.customer = customer; }

  public Long getId() { return id; }
  public String getCustomer() { return customer; }
  public List<OrderItem> getItems() { return items; }
  public void addItem(OrderItem item) { items.add(item); item.setOrder(this); }
}
