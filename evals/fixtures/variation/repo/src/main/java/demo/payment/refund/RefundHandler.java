package demo.payment.refund;

public interface RefundHandler {
  boolean supports(String channel);

  void refund(String paymentId);
}
