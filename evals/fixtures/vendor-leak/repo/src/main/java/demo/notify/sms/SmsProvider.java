package demo.notify.sms;

public interface SmsProvider {
  String code();

  void send(String phone, String text);
}
