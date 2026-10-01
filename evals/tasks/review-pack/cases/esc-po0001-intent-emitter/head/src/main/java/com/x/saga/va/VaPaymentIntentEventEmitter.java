class VaPaymentIntentEventEmitter {
    Intent build(Leg credit) { return new Intent("TOPUP", credit.accountId()); }
}
