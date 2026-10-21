package demo.time;

import org.springframework.stereotype.Component;

@Component
public class SystemClockSource implements ClockSource {
  public long now() {
    return System.currentTimeMillis();
  }
}
