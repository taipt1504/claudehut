package demo.notify;

import org.springframework.stereotype.Component;

@Component
public class EmailNotifier implements Notifier {
  public void notify(String to, String text) {}
}
