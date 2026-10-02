package com.acme.d;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

/** Registers its own public callback address with partners (the deployed value names d-ms itself). */
@Component
public class CallbackRegistrar {
  @Value("${app.callback.base-url}")
  private String callbackUrl;

  public String callback() {
    return callbackUrl;
  }
}
