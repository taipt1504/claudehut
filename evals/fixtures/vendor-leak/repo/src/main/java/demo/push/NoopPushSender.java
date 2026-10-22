package demo.push;

import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.stereotype.Component;

@Component
@ConditionalOnProperty(name = "push.provider", havingValue = "noop")
public class NoopPushSender implements PushSender {
  public void push(String token, String body) {}
}
