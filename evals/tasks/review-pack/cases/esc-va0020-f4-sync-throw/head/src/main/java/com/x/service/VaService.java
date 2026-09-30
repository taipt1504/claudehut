class VaService {
    Mono<Va> create(Req r) { String id = props.producerIdFor(VaType.DYNAMIC); return client.fetch(id).map(Va::of); }
}
