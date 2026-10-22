package demo.push;

import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.stereotype.Component;

@Component
@ConditionalOnProperty(name = "push.provider", havingValue = "apns")
public class ApnsPushSender implements PushSender {
  public void push(String token, String body) {}
}
