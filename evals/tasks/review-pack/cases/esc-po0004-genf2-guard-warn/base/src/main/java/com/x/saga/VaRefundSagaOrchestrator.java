package com.x.saga;

public class VaRefundSagaOrchestrator {
    void confirm(Refund r) {
        advance(r);
    }
}
