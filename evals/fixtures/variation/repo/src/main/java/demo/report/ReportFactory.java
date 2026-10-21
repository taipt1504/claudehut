package demo.report;

import org.springframework.stereotype.Component;

/** N4: a factory that returns a concrete class selects nothing. */
@Component
public class ReportFactory {
  public Report create(String title) {
    return new Report(title);
  }
}
