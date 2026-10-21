#!/usr/bin/env bash
# should-NOT-abstract (M4 guard): the SAME single internal downstream as single-client-no-abstraction, but the repo ALSO has
# an SMS provider family (port + 2 impls + factory), so the variation hint and advisory are live: they must not push a
# speculative abstraction onto an unrelated concern.
set -euo pipefail
P=src/main/java/demo/wallet
mkdir -p $P/client $P/service .claude/claudehut
cat > $P/client/PartyClient.java <<'J'
package demo.wallet.client;

import org.springframework.stereotype.Component;
import org.springframework.web.reactive.function.client.WebClient;
import reactor.core.publisher.Mono;

@Component
public class PartyClient {
  private final WebClient web;

  public PartyClient(WebClient.Builder builder) {
    this.web = builder.baseUrl("http://party-ms").build();
  }

  public Mono<String> customerName(String customerId) {
    return web.get().uri("/internal/api/v1/customers/{id}/name", customerId).retrieve().bodyToMono(String.class);
  }
}
J
cat > $P/service/WalletService.java <<'J'
package demo.wallet.service;

import demo.wallet.client.PartyClient;
import org.springframework.stereotype.Service;
import reactor.core.publisher.Mono;

@Service
public class WalletService {
  private final PartyClient party;

  public WalletService(PartyClient party) {
    this.party = party;
  }

  public Mono<String> ownerLabel(String customerId) {
    return party.customerName(customerId).map(n -> "Owner: " + n);
  }
}
J
printf '{"schema":1,"mode":"mono","language":"en"}\n' > .claude/claudehut/topology.json
Q=src/main/java/demo/infra/outbound/sms
mkdir -p $Q/impl
cat > $Q/SmsProvider.java <<'J'
package demo.infra.outbound.sms;

public interface SmsProvider {
  String code();

  void send(String phone, String text);
}
J
for v in Cmc Fpt; do cat > $Q/impl/${v}SmsProvider.java <<J
package demo.infra.outbound.sms.impl;

import demo.infra.outbound.sms.SmsProvider;
import org.springframework.stereotype.Component;

@Component
public class ${v}SmsProvider implements SmsProvider {
  public String code() {
    return "$v";
  }

  public void send(String phone, String text) {}
}
J
done
cat > $Q/SmsProviderFactory.java <<'J'
package demo.infra.outbound.sms;

import java.util.List;
import java.util.Map;
import java.util.function.Function;
import java.util.stream.Collectors;
import org.springframework.stereotype.Component;

@Component
public class SmsProviderFactory {
  private final Map<String, SmsProvider> byCode;

  public SmsProviderFactory(List<SmsProvider> providers) {
    this.byCode = providers.stream().collect(Collectors.toMap(SmsProvider::code, Function.identity()));
  }

  public SmsProvider get(String code) {
    return byCode.get(code);
  }
}
J
git init -q . && git -c user.email=e@e -c user.name=e add -A && git -c user.email=e@e -c user.name=e commit -qm base
