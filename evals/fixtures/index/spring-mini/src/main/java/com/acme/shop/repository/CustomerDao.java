package com.acme.shop.repository;

import org.springframework.stereotype.Repository;

@Repository
public class CustomerDao {
  public String load(String id) {
    return id;
  }
}
