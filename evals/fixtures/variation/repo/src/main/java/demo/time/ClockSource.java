package demo.time;

/** N2: its second implementation lives only in src/test (a test double, not a production variant). */
public interface ClockSource {
  long now();
}
