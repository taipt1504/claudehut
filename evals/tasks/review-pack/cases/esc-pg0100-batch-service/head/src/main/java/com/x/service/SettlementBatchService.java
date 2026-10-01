class SettlementBatchService {
    Mono<List<Tx>> collect(long b) { return repo.byBatch(b).filter(t -> t.createdAt() != null).collectList(); }
}
