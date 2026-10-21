package demo.notify;

import java.util.Map;
import org.springframework.stereotype.Component;

/** A registry injected as a Map only (Spring keys it by bean name): no List anywhere. */
@Component
public class NotifierHub {
  private final Map<String, Notifier> byName;

  public NotifierHub(Map<String, Notifier> byName) {
    this.byName = byName;
  }
}
