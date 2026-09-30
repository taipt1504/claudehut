package com.x.saga;

public class VaRefundSagaOrchestrator {
    void confirm(Refund r) {
        advance(r);
    }

    String failureCode(BankReply b) {
        return b.code() != null ? b.code() : b.freeText();
    }
}
