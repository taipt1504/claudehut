package com.acme.d;

import java.util.HashMap;
import java.util.Map;
import org.springframework.boot.context.properties.ConfigurationProperties;

/** Map-style topic registry (summer style): spring.kafka.topics.<key>. */
@ConfigurationProperties(prefix = "spring.kafka")
public class DKafkaProperties {
  public static final String TOPIC_E_CMD_KEY = "e-cmd";

  private Map<String, String> topics = new HashMap<>();

  public String getECmdTopic() {
    return getTopic(TOPIC_E_CMD_KEY);
  }

  private String getTopic(String key) {
    return topics.getOrDefault(key, "");
  }
}
