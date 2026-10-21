#!/usr/bin/env bash
# should-NOT-abstract: one internal downstream, no provider family, no commitment to a second implementation.
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
git init -q . && git -c user.email=e@e -c user.name=e add -A && git -c user.email=e@e -c user.name=e commit -qm base
