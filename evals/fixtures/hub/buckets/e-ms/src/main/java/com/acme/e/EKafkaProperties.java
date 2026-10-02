package com.acme.e;

import java.util.HashMap;
import java.util.Map;
import org.springframework.boot.context.properties.ConfigurationProperties;

@ConfigurationProperties(prefix = "spring.kafka")
public class EKafkaProperties {
  public static final String TOPIC_E_CMD_KEY = "e-cmd";
  public static final String TOPIC_E_DONE_KEY = "e-done";

  private Map<String, String> topics = new HashMap<>();

  public String getECmdTopic() {
    return getTopic(TOPIC_E_CMD_KEY);
  }

  public String getEDoneTopic() {
    return getTopic(TOPIC_E_DONE_KEY);
  }

  private String getTopic(String key) {
    return topics.getOrDefault(key, "");
  }
}
