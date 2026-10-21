package demo.notify.sms;

/** Port: one SMS vendor. */
public interface SmsProvider {
  String code();

  void send(String phone, String text);
}
