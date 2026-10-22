package demo.qr;

import org.springframework.stereotype.Component;

@Component
public class DynamicQrStrategy implements QrStrategy {
  public QrType type() {
    return QrType.DYNAMIC;
  }
}
