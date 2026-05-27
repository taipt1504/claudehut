# TTL + Eviction

## TTL guidance

| Data type | TTL |
|-----------|-----|
| Reference data (countries, currencies) | 24h+ |
| User profile | 30 min |
| Auth session | 24h (sliding) |
| Rate-limit counter | 1 min |
| Heavy computation result | 1-12h depending on freshness |
| API response cache | match upstream `Cache-Control` |

## Configure per-namespace

```java
@Bean
public RedisCacheManager cacheManager(RedisConnectionFactory cf, ObjectMapper mapper) {
    var defaults = RedisCacheConfiguration.defaultCacheConfig()
        .entryTtl(Duration.ofMinutes(10))
        .disableCachingNullValues();

    var configs = Map.of(
        "users", defaults.entryTtl(Duration.ofMinutes(30)),
        "sessions", defaults.entryTtl(Duration.ofHours(24)),
        "countries", defaults.entryTtl(Duration.ofHours(24))
    );

    return RedisCacheManager.builder(cf)
        .cacheDefaults(defaults)
        .withInitialCacheConfigurations(configs)
        .build();
}
```

## Eviction policies (server-side)

Redis `maxmemory-policy`:

- `allkeys-lru` — drop least-recently-used. Best for cache use.
- `allkeys-lfu` — least-frequently-used. Better if access pattern stable.
- `volatile-ttl` — drop keys with shortest TTL first.
- `noeviction` — error on write when full. Bad for cache.

Set in `redis.conf` or via CLI: `CONFIG SET maxmemory-policy allkeys-lru`.

## Stale-while-revalidate

For hot keys, serve stale + refresh in background to avoid thundering herd:

```java
public User get(String id) {
    User cached = cache.get(id);
    if (cached != null) {
        if (cache.getTtl(id) < Duration.ofMinutes(1)) {
            executor.submit(() -> refresh(id));  // async refresh
        }
        return cached;
    }
    return refresh(id);
}
```

## Anti-patterns

- Infinite TTL — memory leak.
- TTL longer than data validity window — stale reads.
- `disableCachingNullValues()` not called → cache full of nulls.
- Same TTL across all keys → simultaneous mass-expiration (thundering herd).
- Randomize ±10% to break correlation.
