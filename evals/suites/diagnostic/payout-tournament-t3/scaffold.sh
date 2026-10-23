#!/usr/bin/env bash
# DIAGNOSTIC (M6c): the payout repo of decision/payout-channel-follows-strategy (PayoutChannel strategy + router,
# a one-off direct MoMo top-up client), plus an open full-route task in phase plan for the T3 tournament.
set -euo pipefail
P=src/main/java/demo/payout; W=src/main/java/demo/topup; T=.claudehut/tasks/0001-momo-payout
mkdir -p $P/channel $P/service $W "$T" .claudehut/state
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
printf '{"schema":1,"mode":"mono","language":"en"}\n' > .claudehut/topology.json
git init -q . && git -c user.email=e@e -c user.name=e add -A && git -c user.email=e@e -c user.name=e commit -qm base
base="$(git rev-parse --short HEAD)"
cat > "$T/task.json" <<J
{"schema":2,"id":"0001-momo-payout","route":"full","profile":"feature","phase":"plan","plan_approved":false,
 "review":"pending","plan_review_round":0,"doc_schema":2,"base":{".":"$base"},"pre_dirty":{".":[]},
 "scope":["src/main/*"],"enforcement_set":[],"status":"active","session":"earlier-session","created":"2026-10-20T00:00:00Z"}
J
cat > "$T/task.md" <<'M'
# Task 0001 — MoMo payout
## Acceptance criteria
- AC-001 `PayoutService.payout("MOMO", walletId, amount)` disburses through MoMo and returns its `transId`
M
