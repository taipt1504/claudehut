class MerchantAmlCaseMonitorHandler {
    Mono<App> app(String merchantId) { return apps.findFirstByMerchantIdOrderByCreatedAtDesc(merchantId); }
}
