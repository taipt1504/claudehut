package com.example.infra;

import java.time.Duration;
import java.util.concurrent.CompletableFuture;

/**
 * Distributed, network-backed cache. ASYNC (returns futures), region-scoped, per-region TTL,
 * values are serialized for the wire. Built for cross-node sharing — NOT for in-process memoization.
 */
public interface CacheManager {
    <V> CompletableFuture<V> getAsync(String region, String key, Class<V> type);
    CompletableFuture<Void> putAsync(String region, String key, Object value, Duration ttl);
    CompletableFuture<Void> evictRegion(String region);
}
