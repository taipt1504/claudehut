package demo.time;

import org.springframework.stereotype.Component;

@Component
public class FixedClockSource implements ClockSource {
  public long now() {
    return 0L;
  }
}
