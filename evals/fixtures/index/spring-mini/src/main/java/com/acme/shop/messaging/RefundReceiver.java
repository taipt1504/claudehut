package com.acme.shop.messaging;

import com.acme.shop.config.RefundConsumerProperties;
import java.util.List;
import java.util.Map;
import org.springframework.stereotype.Component;
import reactor.kafka.receiver.KafkaReceiver;
import reactor.kafka.receiver.ReceiverOptions;

@Component
public class RefundReceiver {
  private final RefundConsumerProperties refundProperties;

  public RefundReceiver(RefundConsumerProperties refundProperties) {
    this.refundProperties = refundProperties;
  }

  public void start() {
    KafkaReceiver.create(ReceiverOptions.<String, String>create(Map.of()).subscription(List.of(refundProperties.getTopic())))
        .receive()
        .subscribe();
  }
}
