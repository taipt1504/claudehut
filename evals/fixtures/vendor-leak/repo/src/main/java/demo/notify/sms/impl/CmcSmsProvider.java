package demo.notify.sms.impl;

import demo.notify.sms.SmsProvider;
import org.springframework.stereotype.Component;

@Component
public class CmcSmsProvider implements SmsProvider {
  public String code() {
    return "CMC";
  }

  public void send(String phone, String text) {}
}
