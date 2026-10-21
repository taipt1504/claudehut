package demo.payment.refund;

import org.springframework.stereotype.Service;

@Service
public class CardRefundHandler implements RefundHandler {
  public boolean supports(String channel) {
    return "Card".equalsIgnoreCase(channel);
  }

  public void refund(String paymentId) {}
}
