package com.acme.shop.repository;

import com.acme.shop.entity.Order;
import java.util.UUID;
import org.springframework.data.r2dbc.repository.R2dbcRepository;

public interface OrderRepository extends R2dbcRepository<Order, UUID> {
  Order findByNumber(String number);
}
