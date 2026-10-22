package demo.notify.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

@ConfigurationProperties(prefix = "notify.sms")
public class SmsProperties {
  private String defaultProvider;
  private String cmcApiKey;
}
