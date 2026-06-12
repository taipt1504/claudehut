---
id: rules/performance/caching
paths:
  - "**/*Cache*.java"
  - "**/*CacheConfig*.java"
  - "**/*CacheManager*.java"
severity: medium
stack: "cache=redis,caffeine"
tags: [cache, redis, caffeine, spring-cache, two-level-cache]
---
<!-- ClaudeHut rule template — generated into .claude/rules/performance/caching.md by claudehut-init. Reused & enhanced from committed rules/performance/caching.md. -->

# Caching

## When to cache / not cache

**Cache:** read-heavy with bounded staleness; expensive computation; slow/rate-limited downstream.
**Skip:** per-request unique data; sensitive (GDPR); cheap to compute; high write throughput (invalidation cost > benefit).

## Spring `@Cacheable`

```java
@Cacheable(value = "users", key = "#id", unless = "#result == null")
public User get(String id) { return repo.findById(id).orElse(null); }
@CacheEvict(value = "users", key = "#id")
public void delete(String id) { repo.deleteById(id); }
@CachePut(value = "users", key = "#user.id")
public User update(User user) { return repo.save(user); }
```

## Cache configuration (Redis)

```java
@Bean
public RedisCacheManager cacheManager(RedisConnectionFactory cf, ObjectMapper mapper) {
    RedisCacheConfiguration defaults = RedisCacheConfiguration.defaultCacheConfig()
        .entryTtl(Duration.ofMinutes(10))
        .disableCachingNullValues()
        .serializeValuesWith(SerializationPair.fromSerializer(
            new GenericJackson2JsonRedisSerializer(mapper)));

    return RedisCacheManager.builder(cf)
        .cacheDefaults(defaults)
        .withInitialCacheConfigurations(Map.of(
            "users",    defaults.entryTtl(Duration.ofMinutes(30)),
            "sessions", defaults.entryTtl(Duration.ofHours(24)),
            "config",   defaults.entryTtl(Duration.ofHours(1))))
        .build();
}
```

## Stale-while-revalidate (Caffeine L1)

`refreshAfterWrite` serves stale immediately and reloads in background; requires `LoadingCache` + `CacheLoader`. **Rule:** `refreshAfterWrite` < `expireAfterWrite`; without `expireAfterWrite`, cold keys live forever.

```java
LoadingCache<String, Config> configCache = Caffeine.newBuilder()
    .maximumSize(10_000)
    .expireAfterWrite(Duration.ofMinutes(5))
    .refreshAfterWrite(Duration.ofMinutes(1))
    .build(key -> configService.load(key));
```

## Cache stampede decision table

| Scenario | Mitigation | How |
|---|---|---|
| Single instance, tolerate brief lock | `sync=true` on `@Cacheable` | Spring coalesces concurrent callers to one loader per key |
| Multi-instance, short critical section | Distributed lock (Redisson `tryLock`) | One node recomputes; others block then read | 
| Multi-instance, staleness tolerable | Jittered TTL | `baseT + ThreadLocalRandom.current().nextLong(0, jitter)` |
| High read fan-out, async OK | Request coalescing via `refreshAfterWrite` | Caffeine `LoadingCache` — one background reload, all reads served stale |

`sync=true` is single-JVM only — on multi-instance all nodes still stampede simultaneously.

## Negative caching (cache the miss)

| Situation | Choice | Why |
|---|---|---|
| Expected misses (optional profile data) | Cache `null` with short TTL (5–30 s) | Prevents DB fan-out on hot cold-start paths |
| Penetration attack (random keys flooding) | Cache sentinel with short TTL + rate-limit upstream | `disableCachingNullValues()` means every miss hits DB |
| Legal / correctness (null = "not found" is stale) | `disableCachingNullValues()` | Forces re-check on every request |

To store nulls: remove `disableCachingNullValues()`, keep `unless = ""` on `@Cacheable`. Use a short per-cache TTL.

## Write strategies

| Strategy | Consistency | Write latency | Complexity |
|---|---|---|---|
| Cache-aside (read-through manual) | Eventual (stale window = TTL) | DB only | Low |
| Write-through (`@CachePut` + DB save) | Strong (writer path) | DB + cache | Medium |
| Write-behind (async flush) | Eventual (cache is primary briefly) | Cache only (fast) | High — risk of data loss on crash |

`@Cacheable` = cache-aside. `@CachePut` = write-through. Write-behind requires a dedicated queue/outbox — do not improvise.

## Redis memory pressure & eviction

| Policy | What gets evicted | Risk |
|---|---|---|
| `allkeys-lru` | Any key, LRU order | Evicts session/auth keys with no TTL — silent logout storms |
| `allkeys-lfu` | Any key, LFU order | Same risk as allkeys-lru for infrequently-accessed critical keys |
| `volatile-lru` | Keys **with** TTL only | Safe if ALL critical keys have TTL set |
| `volatile-ttl` | Keys with nearest expiry first | Predictable; set short TTL on eviction-tolerant caches |
| `noeviction` | Nothing — writes fail | Only for primary-store Redis; never for cache-aside Redis |

**Rule:** `volatile-*` policies never evict TTL-less keys — they become immortal. Audit with `OBJECT FREQ <key>` (LFU) or `OBJECT IDLETIME <key>` (LRU).

## Two-level cache (Caffeine L1 + Redis L2)

Use when: L1 hit rate > 80%, Redis latency > 2 ms P99, staleness acceptable.

```java
public User get(String id) {
    User v = l1.getIfPresent(id);         // Caffeine — sub-millisecond
    if (v != null) return v;
    v = (User) l2.get(id);                // Redis
    if (v != null) { l1.put(id, v); return v; }
    v = repo.findById(id).orElse(null);
    if (v != null) { l2.put(id, v); l1.put(id, v); }
    return v;
}
```

**Invalidation across nodes:** publish an invalidation event via Redis pub/sub on write; each node's subscriber calls `l1.invalidate(id)`. Without this, other nodes serve stale until local TTL expires. Set L1 TTL << L2 TTL (e.g., 30 s vs 10 min) to bound staleness without pub/sub for non-critical data.

## Key strategies

| Key | When |
|-----|------|
| Single ID | `key = "#id"` — most common |
| Composite | `key = "{#tenantId, #userId}"` — multi-tenant |
| Hash | `key = "T(my.Util).hash(#req)"` — complex inputs |
| SpEL with method name | `key = "{#root.methodName, #id}"` — methods sharing a cache name |

## TTL guidance

| Data type | TTL |
|-----------|-----|
| Reference data (countries, currencies) | 24 h+ |
| User profile | 30 min |
| Authentication session | 24 h |
| Rate-limit counter | 1 min |
| Heavy computation result | 1–12 h depending on freshness |
| Negative cache (miss) | 5–30 s |
| API response cache | match upstream cache-control |

## Anti-patterns

- Infinite TTL — entries leak forever.
- `disableCachingNullValues()` with no rate-limit — penetration attack empties DB.
- Cache without key strategy — collisions across features.
- JDK serialization (deprecated, insecure) — use JSON serializer.
- Cache as primary store (no DB persistence).
- Heavy objects in cache — denormalize first.
- `allkeys-lru` Redis policy with TTL-less session keys — silent eviction storms.
- `refreshAfterWrite` without `expireAfterWrite` — stale entries live forever if key goes cold.
- L1+L2 without invalidation pub/sub — cross-node reads serve stale after writes.
