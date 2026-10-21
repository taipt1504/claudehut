package demo.qr;

import java.util.EnumMap;
import java.util.List;
import org.springframework.stereotype.Component;

@Component
public class QrRouter {
  private final EnumMap<QrType, QrStrategy> byType = new EnumMap<>(QrType.class);

  public QrRouter(List<QrStrategy> strategies) {
    strategies.forEach(s -> byType.put(s.type(), s));
  }

  public String render(QrType type, String accountNo) {
    return byType.get(type).render(accountNo);
  }
}
