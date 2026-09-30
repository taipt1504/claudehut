package com.acme.shop.entity;

import org.springframework.data.relational.core.mapping.Table;

@Table("orders")
public class Order {
  private String id;
}
