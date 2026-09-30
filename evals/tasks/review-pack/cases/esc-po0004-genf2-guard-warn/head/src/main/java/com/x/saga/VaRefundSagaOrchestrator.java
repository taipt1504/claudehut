package com.x.saga;

public class VaRefundSagaOrchestrator {
    void confirm(Refund r) {
        log.warn("refund {} reached the confirm gate", r.id());
        advance(r);
    }
}
