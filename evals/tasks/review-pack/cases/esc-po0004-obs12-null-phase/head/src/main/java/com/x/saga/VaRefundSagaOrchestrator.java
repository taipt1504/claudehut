package com.x.saga;

public class VaRefundSagaOrchestrator {
    void confirm(Refund r) {
        if (r.phase() == null) {
            complete(r, "refund confirmed");
            return;
        }
        advance(r);
    }
}
