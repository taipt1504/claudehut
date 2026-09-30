package com.acme.shop.client;

import org.springframework.stereotype.Component;
import org.springframework.web.reactive.function.client.WebClient;

/** Talks to the payments service. */
@Component
public class PaymentClient {
  private final WebClient webClient;

  public PaymentClient(WebClient.Builder builder) {
    this.webClient = builder.baseUrl("http://payments.local").build();
  }

  public String pay(String id) {
    return id;
  }
}
