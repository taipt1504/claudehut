package com.acme.a.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

/** Downstream client settings, bound from {@code clients.*}. */
@ConfigurationProperties(prefix = "clients")
public class ClientsProperties {
  private BService bService = new BService();

  public BService getBService() {
    return bService;
  }

  public static class BService {
    private String baseUrl;

    public String getBaseUrl() {
      return baseUrl;
    }
  }
}
