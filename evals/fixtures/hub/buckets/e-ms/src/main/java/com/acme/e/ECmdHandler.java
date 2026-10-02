package com.acme.e;

import java.util.Set;
import org.springframework.stereotype.Component;

/** Summer-style handler: the dispatcher subscribes to getSupportedTopics(). */
@Component
public class ECmdHandler extends AbstractKafkaMessageHandler<String> {
  private final EKafkaProperties kafkaProperties;

  public ECmdHandler(EKafkaProperties kafkaProperties) {
    this.kafkaProperties = kafkaProperties;
  }

  @Override
  public Set<String> getSupportedTopics() {
    return Set.of(kafkaProperties.getECmdTopic());
  }
}
