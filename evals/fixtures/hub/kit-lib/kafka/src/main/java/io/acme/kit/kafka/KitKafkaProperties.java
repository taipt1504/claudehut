package io.acme.kit.kafka;

import org.springframework.boot.context.properties.ConfigurationProperties;

@ConfigurationProperties("kit.kafka")
public record KitKafkaProperties(String groupId, int maxConcurrency) {}
