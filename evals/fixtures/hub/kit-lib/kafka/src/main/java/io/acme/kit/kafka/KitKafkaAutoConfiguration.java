package io.acme.kit.kafka;

import org.springframework.boot.autoconfigure.AutoConfiguration;
import org.springframework.boot.context.properties.EnableConfigurationProperties;

@AutoConfiguration
@EnableConfigurationProperties(KitKafkaProperties.class)
public class KitKafkaAutoConfiguration {}
