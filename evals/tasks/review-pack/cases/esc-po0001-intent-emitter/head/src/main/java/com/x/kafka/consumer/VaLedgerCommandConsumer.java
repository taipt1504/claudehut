class VaLedgerCommandConsumer {
    @KafkaListener(topics = "va.ledger.command.v1")
    void on(String m) {}
}
