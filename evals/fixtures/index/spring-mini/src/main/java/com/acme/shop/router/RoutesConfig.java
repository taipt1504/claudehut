package com.acme.shop.router;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.web.reactive.function.server.RouterFunction;
import org.springframework.web.reactive.function.server.ServerResponse;

@Configuration
public class RoutesConfig {
  @Bean
  public RouterFunction<ServerResponse> routes() {
    return null;
  }
}
