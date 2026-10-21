#!/usr/bin/env bash
# HELD-OUT should-abstract case (M4), frozen before any run: payouts go through a PayoutChannel strategy (Napas,
# Citad) selected by PayoutRouter; WalletTopupService is a one-off direct MoMo client (the precedent the prompt names).
set -euo pipefail
P=src/main/java/demo/payout; W=src/main/java/demo/topup
mkdir -p $P/channel $P/service $W .claude/claudehut
cat > $P/channel/PayoutChannel.java <<'J'
package demo.payout.channel;

import java.math.BigDecimal;

/** One payout rail. */
public interface PayoutChannel {
  String code();

  String payout(String walletId, BigDecimal amount);
}
J
for v in Napas Citad; do cat > $P/channel/${v}PayoutChannel.java <<J
package demo.payout.channel;

import java.math.BigDecimal;
import org.springframework.stereotype.Component;

@Component
public class ${v}PayoutChannel implements PayoutChannel {
  public String code() {
    return "$(echo $v | tr a-z A-Z)";
  }

  public String payout(String walletId, BigDecimal amount) {
    return "$(echo $v | tr A-Z a-z)-" + walletId;
  }
}
J
done
cat > $P/channel/PayoutRouter.java <<'J'
package demo.payout.channel;

import java.util.List;
import java.util.Map;
import java.util.function.Function;
import java.util.stream.Collectors;
import org.springframework.stereotype.Component;

@Component
public class PayoutRouter {
  private final Map<String, PayoutChannel> byCode;

  public PayoutRouter(List<PayoutChannel> channels) {
    this.byCode = channels.stream().collect(Collectors.toMap(PayoutChannel::code, Function.identity()));
  }

  public PayoutChannel get(String code) {
    PayoutChannel c = byCode.get(code);
    if (c == null) {
      throw new IllegalArgumentException("unknown payout channel " + code);
    }
    return c;
  }
}
J
cat > $P/service/PayoutService.java <<'J'
package demo.payout.service;

import demo.payout.channel.PayoutRouter;
import java.math.BigDecimal;
import org.springframework.stereotype.Service;

@Service
public class PayoutService {
  private final PayoutRouter router;

  public PayoutService(PayoutRouter router) {
    this.router = router;
  }

  public String payout(String channel, String walletId, BigDecimal amount) {
    return router.get(channel).payout(walletId, amount);
  }
}
J
cat > $W/WalletTopupService.java <<'J'
package demo.topup;

import java.math.BigDecimal;
import java.util.Map;
import org.springframework.stereotype.Service;
import org.springframework.web.client.RestClient;

/** Top-ups from MoMo: a single direct integration (no other top-up source exists). */
@Service
public class WalletTopupService {
  private final RestClient momo = RestClient.create("https://payment.momo.vn");

  public String topup(String walletId, BigDecimal amount) {
    Map<?, ?> r = momo.post().uri("/v2/gateway/api/create").body(Map.of("walletId", walletId, "amount", amount))
        .retrieve().body(Map.class);
    return String.valueOf(r.get("transId"));
  }
}
J
printf '{"schema":1,"mode":"mono","language":"en"}\n' > .claude/claudehut/topology.json
git init -q . && git -c user.email=e@e -c user.name=e add -A && git -c user.email=e@e -c user.name=e commit -qm base
