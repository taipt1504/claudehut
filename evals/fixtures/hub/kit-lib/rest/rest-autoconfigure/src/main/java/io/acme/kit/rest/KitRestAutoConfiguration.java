package io.acme.kit.rest;

import io.acme.kit.core.IdGenerator;
import java.util.UUID;
import org.springframework.boot.autoconfigure.AutoConfiguration;
import org.springframework.boot.autoconfigure.condition.ConditionalOnMissingBean;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.annotation.Bean;

@AutoConfiguration
@EnableConfigurationProperties(KitRestProperties.class)
public class KitRestAutoConfiguration {

  @Bean
  @ConditionalOnMissingBean
  public IdGenerator idGenerator() {
    return () -> UUID.randomUUID().toString();
  }
}
