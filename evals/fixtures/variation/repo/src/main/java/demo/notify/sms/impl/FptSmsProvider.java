package demo.notify.sms.impl;

import demo.notify.sms.SmsProvider;
import org.springframework.stereotype.Component;

@Component
public class FptSmsProvider implements SmsProvider {
  @Override
  public String code() {
    return "FPT";
  }

  @Override
  public void send(String phone, String text) {}
}
