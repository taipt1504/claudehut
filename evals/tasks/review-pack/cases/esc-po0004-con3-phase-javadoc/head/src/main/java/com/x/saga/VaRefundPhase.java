package com.x.saga;

/** Never null once the saga has started; every refund carries a phase. */
public enum VaRefundPhase {
    AWAIT_HOLD,
    AWAIT_BANK_REFUND_CONFIRM
}
