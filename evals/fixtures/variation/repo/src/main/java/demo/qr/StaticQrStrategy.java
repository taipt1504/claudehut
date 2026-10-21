package demo.qr;

import org.springframework.stereotype.Component;

@Component
public class StaticQrStrategy implements QrStrategy {
  public QrType type() {
    return QrType.STATIC;
  }

  public String render(String accountNo) {
    return accountNo;
  }
}
