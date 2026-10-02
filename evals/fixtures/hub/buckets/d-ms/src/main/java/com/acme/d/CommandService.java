package com.acme.d;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;

/** Writes outbox rows: an explicit topic (4 args), and a type the topic-prefix completes (3 args). */
@Service
public class CommandService {
  private final OutboxService outboxService;

  @Value("${d.cmd.topic:f.cmd.v1}")
  private String cmdTopic;

  public CommandService(OutboxService outboxService) {
    this.outboxService = outboxService;
  }

  public void command(String id, String payload) {
    outboxService.saveEvent(id, "cmd", payload, cmdTopic);
    outboxService.saveEvent(id, "link.notify", payload);
  }
}
