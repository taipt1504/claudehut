---
id: rules/framework/redis
paths:
  - "**/*Redis*.java"
  - "**/*CacheConfig*.java"
  - "**/cache/*.java"
stack: "cache=redis"
severity: medium
tags: [redis, cache, distributed-lock, stampede]
---
<!-- ClaudeHut rule template — generated into .claude/rules/framework/redis.md by claudehut-init. Reused & enhanced from committed rules/framework/redis.md. -->

# Redis / Spring Cache Rules

## DO

- `@EnableCaching` on config class; use `RedisCacheManagerBuilderCustomizer` for per-cache TTL (doesn't replace Boot auto-config).
- `GenericJackson2JsonRedisSerializer` with your `ObjectMapper` — never JDK serialization.
- Explicit TTL per cache namespace. No `entryTtl` → entries leak forever.
- `sync = true` on `@Cacheable` — Spring serializes concurrent loaders per key (single-JVM stampede guard).
- TTL jitter for bulk-expiring keys: `entryTtl(base.plusSeconds(ThreadLocalRandom.current().nextLong(60)))`.
- Namespace keys: `<service>:<entity>:<id>`; Spring Boot adds `<cacheName>::` prefix automatically.
- Add version segment for schema evolution: `myapp:v2:user:<id>` — bump `v2` → `v3` on DTO changes.
- Redisson `tryLock` for distributed stampede guard (cross-node, non-Spring callers).
- Pool: configure `spring.data.redis.lettuce.pool.*` (max-active ≥ 8, max-idle = max-active, min-idle = 2).
- `@CacheEvict` default `beforeInvocation = false` — eviction fires after commit; rollback leaves entry intact (correct).

## DON'T

- **JDK serialization** — brittle across JVM versions + class refactors break deserialization silently at runtime.
- **`beforeInvocation = true` on `@CacheEvict`** — evicts before write; method throws → stale entry gone, next read repopulates pre-write data.
- **Custom `SETNX` / `setIfAbsent + expire`** — two non-atomic calls; process crash between them leaves orphan lock.
- **`@CachePut` + `@Cacheable` on the same method** — `@CachePut` always invokes; `@Cacheable` never reads the cache.
- **Cache `Page<T>` or heavy collections** — denormalize to IDs.
- Keys without namespace — cross-service collisions on shared Redis.

## Serializer — why it matters

| Serializer | Class rename | JVM compat | Human-readable |
|---|---|---|---|
| `JdkSerializationRedisSerializer` (default) | **Breaks** (ClassCastException) | Tied to serialVersionUID | No |
| `GenericJackson2JsonRedisSerializer` | Safe (field mapping) | Any JVM | Yes |

Register `JavaTimeModule` + `WRITE_DATES_AS_TIMESTAMPS = false` on the `ObjectMapper` or `LocalDate`/`Instant` serialize as arrays.

## Stampede control decision table

| Scenario | Tool | Why |
|---|---|---|
| Single JVM | `@Cacheable(sync = true)` | Spring per-key lock, zero infra |
| Multi-instance, Spring callers | Redisson `tryLock` + double-check | `sync=true` scope is per-JVM |
| Bulk expiry (cron-loaded keys) | TTL jitter on write | Spreads expiry; no lock needed |
| Multi-instance + non-Spring callers | Redisson `tryLock` | Same Redisson lock key seen by all |

`sync = true` is NOT enough when multiple app instances share one Redis — a second pod still misses and loads concurrently.

## Eviction policy (Redis server `maxmemory-policy`)

| Policy | Use when |
|---|---|
| `allkeys-lru` | Cache-only Redis; evict least-recently-used regardless of TTL |
| `volatile-lru` | Mixed Redis (cache + durable keys); only evict keys with TTL set |
| `volatile-ttl` | Prefer evicting keys expiring soonest — good for session stores |
| `noeviction` | **Never** for cache — OOM errors under pressure |

Default is `noeviction`. Set `maxmemory` + `maxmemory-policy allkeys-lru` for pure caches.

## Negative caching

- Default: `disableCachingNullValues()` — null returns skip cache; absent entities always hit DB.
- **Cache nulls intentionally** only for high-volume known-absent lookups (fraud/block-list checks). Use a sentinel DTO + short TTL (30–60 s). Raw `null` won't store — Spring skips it unless `unless = ""` is omitted.

## Configuration

```java
@Configuration @EnableCaching
public class CacheConfig {

    @Bean
    public RedisCacheConfiguration redisCacheConfiguration(ObjectMapper mapper) {
        // Global default: JSON serializer, 10-min TTL, no nulls.
        // Boot auto-config picks this bean up — no need to replace RedisCacheManager.
        return RedisCacheConfiguration.defaultCacheConfig()
            .entryTtl(Duration.ofMinutes(10))
            .disableCachingNullValues()
            .serializeValuesWith(RedisSerializationContext.SerializationPair.fromSerializer(
                new GenericJackson2JsonRedisSerializer(mapper)));
    }

    @Bean
    public RedisCacheManagerBuilderCustomizer cacheCustomizer() {
        return builder -> builder
            .withCacheConfiguration("users",          // 30 min + jitter
                RedisCacheConfiguration.defaultCacheConfig()
                    .entryTtl(Duration.ofMinutes(30).plusSeconds(
                        ThreadLocalRandom.current().nextLong(60))));
    }
}
```

## Correct usage

```java
// sync=true: one thread loads; others wait. unless: don't store absent users.
@Cacheable(cacheNames = "users", key = "#id", sync = true, unless = "#result == null")
public UserDto get(String id) { ... }

// Evict after commit (beforeInvocation=false is the default — keep it)
@CacheEvict(cacheNames = "users", key = "#id")
@Transactional
public void delete(String id) { repo.deleteById(id); }
```

## Distributed lock (multi-instance stampede)

```java
// Use when sync=true isn't enough: multiple pods share one Redis.
public UserDto getWithLock(String id) {
    Cache cache = cacheManager.getCache("users");
    UserDto hit = cache.get(id, UserDto.class);
    if (hit != null) return hit;
    RLock lock = redisson.getLock("cache-load:users:" + id);
    try {
        if (lock.tryLock(3, 10, TimeUnit.SECONDS)) {
            hit = cache.get(id, UserDto.class);    // double-check after lock
            if (hit != null) return hit;
            UserDto fresh = repo.findById(id).map(UserDto::from).orElseThrow();
            cache.put(id, fresh);
            return fresh;
        }
        throw new CacheLoadException("lock timeout: user " + id);
    } catch (InterruptedException e) {
        Thread.currentThread().interrupt();
        throw new CacheLoadException("interrupted", e);
    } finally {
        if (lock.isHeldByCurrentThread()) lock.unlock();
    }
}
```

## Anti-patterns

```java
// BAD — beforeInvocation=true: evicts before write; on exception, entry gone, stale data re-cached
@CacheEvict(cacheNames = "users", key = "#id", beforeInvocation = true)
@Transactional
public void delete(String id) { repo.deleteById(id); }

// BAD — JDK serializer: MyDto rename → ClassCastException in production
RedisCacheConfiguration.defaultCacheConfig();   // no .serializeValuesWith() call

// BAD — SETNX race: crash between these two lines → lock never released
Boolean ok = redis.opsForValue().setIfAbsent("lock:" + id, "1");
redis.expire("lock:" + id, 10, TimeUnit.SECONDS);   // not atomic
```

## References

- Distributed lock playbook + jitter examples: `claudehut:implement` skill.
