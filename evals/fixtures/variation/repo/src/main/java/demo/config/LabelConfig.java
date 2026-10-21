package demo.config;

import java.util.List;
import java.util.Map;
import org.springframework.stereotype.Component;

/** N3/N6: a Map<String, String> and a List<String> are data, not a registry of a port. */
@Component
public class LabelConfig {
  private final Map<String, String> labels;
  private final List<String> locales;

  public LabelConfig(Map<String, String> labels, List<String> locales) {
    this.labels = labels;
    this.locales = locales;
  }
}
