package com.acme.c.kafka;

import java.util.List;
import java.util.Map;
import reactor.kafka.receiver.KafkaReceiver;
import reactor.kafka.receiver.ReceiverOptions;

/** reactor-kafka receiver factory: it only sees a parameter, so it is not a consumer itself. */
public final class KafkaConfigUtil {
  private KafkaConfigUtil() {}

  public static KafkaReceiver<String, String> createReceiver(ReactiveConsumerProperties props) {
    ReceiverOptions<String, String> options =
        ReceiverOptions.<String, String>create(Map.of()).subscription(List.of(props.getTopic()));
    return KafkaReceiver.create(options);
  }
}
