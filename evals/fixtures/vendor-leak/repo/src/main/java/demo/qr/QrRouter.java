package demo.qr;

import java.util.List;
import org.springframework.stereotype.Component;

@Component
public class QrRouter {
  private final List<QrStrategy> strategies;

  public QrRouter(List<QrStrategy> strategies) {
    this.strategies = strategies;
  }
}
