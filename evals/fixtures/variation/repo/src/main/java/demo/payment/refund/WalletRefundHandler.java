package demo.payment.refund;

import org.springframework.stereotype.Service;

@Service
public class WalletRefundHandler implements RefundHandler {
  public boolean supports(String channel) {
    return "Wallet".equalsIgnoreCase(channel);
  }

  public void refund(String paymentId) {}
}
