interface SettlementTransactionRepository {
    @Query("select * from settlement_transaction where batch_id = :b")
    Flux<Tx> byBatch(long b);
}
