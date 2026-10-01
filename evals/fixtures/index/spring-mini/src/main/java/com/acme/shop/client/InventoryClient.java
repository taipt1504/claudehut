package com.acme.shop.client;

import org.springframework.cloud.openfeign.FeignClient;
import org.springframework.web.bind.annotation.GetMapping;

@FeignClient(name = "inventory", url = "http://inventory:8080/api")
public interface InventoryClient {
  @GetMapping("/stock/{sku}")
  int stock(String sku);
}
