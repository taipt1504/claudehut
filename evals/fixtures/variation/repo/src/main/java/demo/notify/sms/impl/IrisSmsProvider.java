package demo.notify.sms.impl;

import demo.notify.sms.SmsProvider;
import org.springframework.stereotype.Component;

@Component
public class IrisSmsProvider implements SmsProvider {
  @Override
  public String code() {
    return "IRIS";
  }

  @Override
  public void send(String phone, String text) {}
}
