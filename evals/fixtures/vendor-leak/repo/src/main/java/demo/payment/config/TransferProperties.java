package demo.payment.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

@ConfigurationProperties(prefix = "napas")
public class TransferProperties {
  private String endpoint;
}
