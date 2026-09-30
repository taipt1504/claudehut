package com.x.domain;

import jakarta.persistence.Entity;
import jakarta.persistence.Table;

@Entity
@Table(name = "orders")
public class Order {
    private String note;
}
