#!/usr/bin/env bash
# P1 (pgw 0081): the endpoint already takes `bank`; the first bank asked for is TCB. Rule (b): the variation is
# committed by the contract, so the file layout must be chosen per bank, not hard-coded to TCB.
set -euo pipefail
P=src/main/java/demo/settlement
mkdir -p $P/api $P/service $P/domain .claude/claudehut
cat > $P/api/PaymentFileController.java <<'J'
package demo.settlement.api;

import demo.settlement.service.PaymentFileService;
import java.time.LocalDate;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class PaymentFileController {
  private final PaymentFileService service;

  public PaymentFileController(PaymentFileService service) {
    this.service = service;
  }

  /** Daily payment file for a partner bank, e.g. bank=TCB. */
  @GetMapping("/backoffice/api/v1/payment-files")
  public byte[] export(@RequestParam String bank, @RequestParam LocalDate day) {
    return service.export(bank, day);
  }
}
J
cat > $P/domain/Payment.java <<'J'
package demo.settlement.domain;

import java.math.BigDecimal;

public record Payment(String id, String accountNo, String accountName, BigDecimal amount, String content) {}
J
cat > $P/service/PaymentFileService.java <<'J'
package demo.settlement.service;

import demo.settlement.domain.Payment;
import java.time.LocalDate;
import java.util.List;
import org.springframework.stereotype.Service;

@Service
public class PaymentFileService {
  public byte[] export(String bank, LocalDate day) {
    List<Payment> payments = load(day);
    throw new UnsupportedOperationException("TODO: build the file for " + bank + " with " + payments.size() + " rows");
  }

  List<Payment> load(LocalDate day) {
    return List.of();
  }
}
J
printf '{"schema":1,"mode":"mono","language":"en"}\n' > .claude/claudehut/topology.json
git init -q . && git -c user.email=e@e -c user.name=e add -A && git -c user.email=e@e -c user.name=e commit -qm base
