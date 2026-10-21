package demo.payment.refund;

import java.util.List;
import org.springframework.stereotype.Service;

@Service
public class RefundDispatcher {
  private final List<RefundHandler> handlers;

  public RefundDispatcher(List<RefundHandler> handlers) {
    this.handlers = handlers;
  }

  public void refund(String channel, String paymentId) {
    handlers.stream().filter(h -> h.supports(channel)).findFirst().orElseThrow().refund(paymentId);
  }
}
