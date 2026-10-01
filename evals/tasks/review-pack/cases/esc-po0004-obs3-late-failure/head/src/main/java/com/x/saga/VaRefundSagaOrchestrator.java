package com.x.saga;

public class VaRefundSagaOrchestrator {
    void confirm(Refund r) {
        advance(r);
    }

    void ignoreLateFailure(Refund r) {
        log.warn("late bank failure ignored for refund {}", r.id());
    }
}
