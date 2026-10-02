package com.acme.d;

import java.util.HashMap;
import java.util.Map;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;

/** UI links handed to users inside emails: email model data and a mail-context argument, never a client. */
@Service
public class UserMailer {
  private final DProps props;
  private final MailSender sender;

  @Value("${app.backoffice-url}")
  private String backofficeUrl;

  public UserMailer(DProps props, MailSender sender) {
    this.props = props;
    this.sender = sender;
  }

  public void welcome(String email) {
    Map<String, String> data = new HashMap<>();
    if (backofficeUrl != null && !backofficeUrl.isBlank()) {
      data.put("systemUrl", backofficeUrl);
    }
    sender.send(email, data);
  }

  public void onboarded(String email) {
    sender.sendOwnerOnboarded(new OwnerMailContext(email, props.getMerchantPortal().getUrl()));
    sender.send(email, Map.of("loginUrl", props.getMerchantPortal().getUrl()));
  }
}
