package com.acme.e;

import java.util.HashMap;
import java.util.Map;
import org.springframework.boot.context.properties.ConfigurationProperties;

@ConfigurationProperties(prefix = "spring.kafka")
public class EKafkaProperties {
  public static final String TOPIC_E_CMD_KEY = "e-cmd";

  private Map<String, String> topics = new HashMap<>();

  public String getECmdTopic() {
    return getTopic(TOPIC_E_CMD_KEY);
  }

  private String getTopic(String key) {
    return topics.getOrDefault(key, "");
  }
}
