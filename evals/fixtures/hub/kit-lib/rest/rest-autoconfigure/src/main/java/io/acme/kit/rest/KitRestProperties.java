package io.acme.kit.rest;

import java.time.Duration;
import java.util.LinkedHashMap;
import java.util.Map;
import org.springframework.boot.context.properties.ConfigurationProperties;

@ConfigurationProperties(prefix = "kit.rest")
public class KitRestProperties {

  public static final String DEFAULT_NAME = "kit";

  private boolean enabled = true;
  private Duration readTimeout = Duration.ofSeconds(30);
  private final Retry retry = new Retry();
  private Map<String, Client> clients = new LinkedHashMap<>();

  public static class Retry {
    private int maxAttempts = 3;
  }

  public static class Client {
    private String baseUrl;
  }
}
