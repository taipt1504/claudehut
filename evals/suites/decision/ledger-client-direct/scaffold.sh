#!/usr/bin/env bash
# HELD-OUT should-not (M4 reopened), frozen before any lever change: wallet service with a live SMS provider family
# (so the index finds a port + selector family) and no ledger client yet; the request creates one internal client.
set -euo pipefail
Q=src/main/java/demo/infra/sms; W=src/main/java/demo/wallet
mkdir -p $Q/impl $W/service $W/domain .claudehut
cat > $Q/SmsProvider.java <<'J'
package demo.infra.sms;

public interface SmsProvider {
  String code();

  boolean send(String phone, String text);
}
J
for v in Cmc Fpt; do cat > $Q/impl/${v}SmsProvider.java <<J
package demo.infra.sms.impl;

import demo.infra.sms.SmsProvider;
import org.springframework.stereotype.Component;

@Component
public class ${v}SmsProvider implements SmsProvider {
  @Override
  public String code() {
    return "$(echo $v | tr a-z A-Z)";
  }

  @Override
  public boolean send(String phone, String text) {
    return true;
  }
}
J
done
cat > $Q/SmsProviderFactory.java <<'J'
package demo.infra.sms;

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
cat > $W/domain/Wallet.java <<'J'
package demo.wallet.domain;

public record Wallet(String accountId, String ownerId) {}
J
cat > $W/service/WalletService.java <<'J'
package demo.wallet.service;

import demo.wallet.domain.Wallet;
import org.springframework.stereotype.Service;

@Service
public class WalletService {
  public Wallet open(String accountId, String ownerId) {
    return new Wallet(accountId, ownerId);
  }
}
J
printf '{"schema":1,"mode":"mono","language":"en"}\n' > .claudehut/topology.json
git init -q . && git -c user.email=e@e -c user.name=e add -A && git -c user.email=e@e -c user.name=e commit -qm base
