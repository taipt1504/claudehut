package demo.notify.sms.impl;

import demo.notify.sms.SmsProvider;
import org.springframework.stereotype.Component;

@Component
public class FptSmsProvider implements SmsProvider {
  public String code() {
    return "FPT";
  }

  public void send(String phone, String text) {}
}
