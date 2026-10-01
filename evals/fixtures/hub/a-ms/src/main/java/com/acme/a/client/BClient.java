package com.acme.a.client;

import com.acme.a.config.ClientsProperties;
import org.springframework.stereotype.Component;
import org.springframework.web.reactive.function.client.WebClient;
import reactor.core.publisher.Mono;

/** Calls b-ms order endpoints. */
@Component
public class BClient {
  private final WebClient webClient;

  public BClient(WebClient.Builder builder, ClientsProperties props) {
    this.webClient = builder.baseUrl(props.getBService().getBaseUrl()).build();
  }

  public Mono<String> order(String id) {
    return webClient.get().uri("/api/v1/orders/{id}", id).retrieve().bodyToMono(String.class);
  }
}
