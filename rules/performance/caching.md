---
id: rules/performance/caching
applies-to: "**/*Service.java, **/*Cache*.java"
severity: medium
tags: [cache, redis, spring-cache]
---

# Caching

## When to cache

- Read-heavy data.
- Computation expensive to repeat.
- Downstream service slow or rate-limited.
- Result valid for some bounded time.

## When NOT to cache

- Per-request unique data (no reuse).
- Sensitive data (audit / GDPR concerns).
- Cheap to compute (caching overhead > saved time).
- High write throughput (cache invalidation cost outweighs).

## Spring `@Cacheable`

```java
@Service
@RequiredArgsConstructor
public class UserService {

    @Cacheable(value = "users", key = "#id", unless = "#result == null")
    public User get(String id) {
        return repo.findById(id).orElse(null);
    }

    @CacheEvict(value = "users", key = "#id")
    public void delete(String id) {
        repo.deleteById(id);
    }

    @CachePut(value = "users", key = "#user.id")
    public User update(User user) {
        return repo.save(user);
    }
}
```

## Cache configuration

```java
@Bean
public RedisCacheManager cacheManager(RedisConnectionFactory cf, ObjectMapper mapper) {
    RedisCacheConfiguration defaults = RedisCacheConfiguration.defaultCacheConfig()
        .entryTtl(Duration.ofMinutes(10))
        .disableCachingNullValues()
        .serializeValuesWith(SerializationPair.fromSerializer(
            new GenericJackson2JsonRedisSerializer(mapper)));

    Map<String, RedisCacheConfiguration> caches = Map.of(
        "users", defaults.entryTtl(Duration.ofMinutes(30)),
        "sessions", defaults.entryTtl(Duration.ofHours(24)),
        "config", defaults.entryTtl(Duration.ofHours(1))
    );

    return RedisCacheManager.builder(cf)
        .cacheDefaults(defaults)
        .withInitialCacheConfigurations(caches)
        .build();
}
```

## Key strategies

| Key | When |
|-----|------|
| Single ID | `key = "#id"` — most common |
| Composite | `key = "{#tenantId, #userId}"` — multi-tenant |
| Hash | `key = "T(my.Util).hash(#req)"` — complex inputs |
| SpEL with method name | `key = "{#root.methodName, #id}"` — methods with same cache name |

## TTL guidance

| Data type | TTL |
|-----------|-----|
| Reference data (countries, currencies) | 24h+ |
| User profile | 30 min |
| Authentication session | 24h |
| Rate-limit counter | 1 min |
| Heavy computation result | 1-12h depending on freshness |
| API response cache | match upstream cache-control |

## Cache-aside pattern

```java
public User get(String id) {
    User cached = cache.get(id);
    if (cached != null) return cached;
    User fresh = repo.findById(id).orElse(null);
    if (fresh != null) cache.put(id, fresh, Duration.ofMinutes(30));
    return fresh;
}
```

`@Cacheable` does this for you.

## Thundering herd

When a hot key expires, many concurrent requests recompute. Mitigations:

- Stale-while-revalidate: serve stale, refresh in background.
- Per-key lock: only one request recomputes; others wait.
- Randomize TTL: avoid simultaneous expiration of related keys.

```java
public User get(String id) {
    return cache.computeIfAbsent(id, k -> {
        RLock lock = redisson.getLock("cache-lock:" + k);
        try {
            lock.lock();
            User cached = cache.get(k);
            if (cached != null) return cached;
            return repo.findById(k).orElse(null);
        } finally {
            lock.unlock();
        }
    });
}
```

## Cache invalidation

| Strategy | When |
|----------|------|
| TTL-only | Stale tolerable; simple |
| Explicit evict on write | Strong consistency |
| Event-based invalidation | Cross-service consistency |

## Anti-patterns

- Infinite TTL — entries leak forever.
- Caching null without `disableCachingNullValues()`.
- Cache without key strategy — collisions across features.
- JDK serialization (deprecated, insecure) — use JSON serializer.
- Cache as primary store (no DB persistence).
- Heavy objects in cache (denormalize first).
