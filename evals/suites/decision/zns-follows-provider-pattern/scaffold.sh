#!/usr/bin/env bash
# notification-ms in miniature (appendix a1, case N1): SMS already goes through SmsProvider + SmsProviderFactory.
set -euo pipefail
P=src/main/java/demo/notification
Q=src/main/java/demo/infra/outbound
mkdir -p $Q/sms/impl $P/service $P/api $P/domain src/main/resources/db/migration .claude/claudehut
cat > $Q/sms/SmsProvider.java <<'J'
package demo.infra.outbound.sms;

public interface SmsProvider {
  String code();

  SendResult send(String phone, String text);
}
J
cat > $Q/sms/SendResult.java <<'J'
package demo.infra.outbound.sms;

public record SendResult(boolean accepted, String providerMessageId) {}
J
for v in Cmc Fpt; do cat > $Q/sms/impl/${v}SmsProvider.java <<J
package demo.infra.outbound.sms.impl;

import demo.infra.outbound.sms.SendResult;
import demo.infra.outbound.sms.SmsProvider;
import org.springframework.stereotype.Component;

@Component
public class ${v}SmsProvider implements SmsProvider {
  @Override
  public String code() {
    return "$(echo $v | tr a-z A-Z)";
  }

  @Override
  public SendResult send(String phone, String text) {
    return new SendResult(true, "$(echo $v | tr A-Z a-z)-" + phone.hashCode());
  }
}
J
done
cat > $Q/sms/SmsProviderFactory.java <<'J'
package demo.infra.outbound.sms;

import java.util.List;
import java.util.Map;
import java.util.function.Function;
import java.util.stream.Collectors;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

@Component
public class SmsProviderFactory {
  private final Map<String, SmsProvider> byCode;
  private final String active;

  public SmsProviderFactory(List<SmsProvider> providers, @Value("${sms.provider:CMC}") String active) {
    this.byCode = providers.stream().collect(Collectors.toMap(SmsProvider::code, Function.identity()));
    this.active = active;
  }

  public SmsProvider active() {
    SmsProvider p = byCode.get(active);
    if (p == null) {
      throw new IllegalStateException("unknown sms provider " + active);
    }
    return p;
  }
}
J
cat > $P/service/SmsService.java <<'J'
package demo.notification.service;

import demo.infra.outbound.sms.SendResult;
import demo.infra.outbound.sms.SmsProviderFactory;
import org.springframework.stereotype.Service;

@Service
public class SmsService {
  private final SmsProviderFactory factory;

  public SmsService(SmsProviderFactory factory) {
    this.factory = factory;
  }

  public SendResult send(String phone, String text) {
    return factory.active().send(phone, text);
  }
}
J

# noise: unrelated services, DTOs and a push sender wired directly (an older, worse precedent nearby)
for n in Template Recipient Channel Priority Locale Quota Audit Retry; do
cat > $P/domain/$n.java <<J
package demo.notification.domain;

public record $n(String id, String value) {}
J
cat > $P/service/${n}Service.java <<J
package demo.notification.service;

import org.springframework.stereotype.Service;

@Service
public class ${n}Service {
  public String describe(String id) {
    return "$n:" + id;
  }
}
J
done
cat > $P/service/PushService.java <<'J'
package demo.notification.service;

import org.springframework.stereotype.Service;
import org.springframework.web.reactive.function.client.WebClient;

@Service
public class PushService {
  private final WebClient oneSignal = WebClient.create("https://api.onesignal.com");

  public void push(String deviceToken, String message) {
    oneSignal.post().uri("/notifications").bodyValue(java.util.Map.of("token", deviceToken, "msg", message))
        .retrieve().toBodilessEntity().block();
  }
}
J
printf 'create table sms_audit (id uuid primary key, phone varchar(20), provider varchar(16), provider_message_id varchar(64));\n' > src/main/resources/db/migration/V1__sms_audit.sql
printf '{"schema":1,"mode":"mono","language":"en"}\n' > .claude/claudehut/topology.json
git init -q . && git -c user.email=e@e -c user.name=e add -A && git -c user.email=e@e -c user.name=e commit -qm base
