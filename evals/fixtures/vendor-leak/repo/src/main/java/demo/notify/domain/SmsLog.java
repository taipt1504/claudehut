package demo.notify.domain;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;

@Entity
public class SmsLog {
  @Id private Long id;

  @Column(name = "provider_message_id")
  private String providerMessageId;

  @Column(name = "fpt_message_id")
  private String fptMessageId;

  private String confirmedBy;
}
