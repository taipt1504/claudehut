package demo.qr;

public interface QrStrategy {
  QrType type();

  String render(String accountNo);
}
