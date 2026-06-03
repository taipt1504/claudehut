# Redis + Spring Cache

<!-- Researched via Spring Data Redis (/spring-projects/spring-data-redis) and Spring Boot 3.4 (/websites/spring_io_spring-boot_3_4) on context7. Spring Boot 3.2+/Java 17+. -->

**When:** `*CacheConfig.java`, `cache/` packages, `@Cacheable` usage, `RedisTemplate` wiring.

---

## DO

- Annotate config class with `@EnableCaching`.
- Use `GenericJackson2JsonRedisSerializer` — never JDK serialization.
- Set explicit TTL per cache via `withCacheConfiguration` (or `RedisCacheManagerBuilderCustomizer`).
- Namespace keys: `<service>:<entity>:<id>`; rely on Spring's default cache-name prefix or set one explicitly.
- Use `disableCachingNullValues()` unless you deliberately need negative caching.
- Use `sync = true` on `@Cacheable` for stampede (thundering-herd) protection — Spring serialises concurrent loaders per key.
- Evict **after** commit (`@CacheEvict` on the same `@Transactional` method runs after commit by default when `beforeInvocation = false`).
- Add TTL jitter for keys that expire together: `entryTtl(base.plusSeconds(ThreadLocalRandom.current().nextLong(30)))`.
- Use Redisson `tryLock` for distributed stampede guard when `sync = true` is insufficient (cross-node, non-Spring flows).
- Configure pool: `spring.data.redis.lettuce.pool.*` (max-active, max-idle, min-idle).

## DON'T

- `new JdkSerializationRedisSerializer()` — brittle across JVM versions, insecure.
- Infinite TTL — entries leak forever; always set `entryTtl`.
- `@CacheEvict` with `beforeInvocation = true` — evicts before the write lands, concurrent reader repopulates stale.
- Cache mutable objects without defensive copy or immutable DTO.
- Custom `SETNX` / manual `setIfAbsent + expire` for locks — race between the two calls; use Redisson.
- Keys without namespace — collision across services sharing one Redis.
- `@CachePut` and `@Cacheable` on the same method — `@CachePut` always writes, so `@Cacheable` never reads.
- Cache `Page<T>` or heavy collections — denormalize to IDs first.

---

## Correct example

```java
// CacheConfig.java
@Configuration
@EnableCaching
public class CacheConfig {

    @Bean
    public RedisCacheManagerBuilderCustomizer cacheCustomizer() {
        // Per-cache TTL via customizer — integrates with Spring Boot auto-config,
        // no need to replace the whole RedisCacheManager bean.
        return builder -> builder
            .withCacheConfiguration("users",
                RedisCacheConfiguration.defaultCacheConfig()
                    .entryTtl(Duration.ofMinutes(30))
                    .disableCachingNullValues())
            .withCacheConfiguration("sessions",
                RedisCacheConfiguration.defaultCacheConfig()
                    .entryTtl(Duration.ofHours(24))
                    .disableCachingNullValues())
            .withCacheConfiguration("config",
                RedisCacheConfiguration.defaultCacheConfig()
                    .entryTtl(Duration.ofHours(1)));
    }

    // Override default serializer globally via a RedisCacheConfiguration bean.
    // Spring Boot auto-config picks this up.
    @Bean
    public RedisCacheConfiguration redisCacheConfiguration(ObjectMapper mapper) {
        return RedisCacheConfiguration.defaultCacheConfig()
            .entryTtl(Duration.ofMinutes(10))
            .disableCachingNullValues()
            .serializeValuesWith(RedisSerializationContext.SerializationPair.fromSerializer(
                new GenericJackson2JsonRedisSerializer(mapper)));
    }
}

// UserService.java
@Service
@RequiredArgsConstructor
public class UserService {

    private final UserRepository repo;

    // sync=true: Spring holds a per-key lock so only one thread loads on cache miss.
    // unless: don't cache null returns (absent user).
    @Cacheable(cacheNames = "users", key = "#id", sync = true, unless = "#result == null")
    public UserDto get(String id) {
        return repo.findById(id).map(UserDto::from).orElse(null);
    }

    // CachePut: always writes the fresh value after a save.
    @CachePut(cacheNames = "users", key = "#result.id")
    public UserDto update(UserDto dto) {
        return UserDto.from(repo.save(dto.toEntity()));
    }

    // CacheEvict after commit (beforeInvocation=false is the default).
    @CacheEvict(cacheNames = "users", key = "#id")
    @Transactional
    public void delete(String id) {
        repo.deleteById(id);
    }
}
```

### Programmatic cache-aside with jitter (when you need RedisTemplate directly)

```java
@Service
@RequiredArgsConstructor
public class ProductCacheService {

    private final StringRedisTemplate redis;
    private final ObjectMapper mapper;
    private static final Duration BASE_TTL = Duration.ofMinutes(15);

    public ProductDto get(String id) throws Exception {
        String key = "myapp:product:" + id;
        String raw = redis.opsForValue().get(key);
        if (raw != null) return mapper.readValue(raw, ProductDto.class);

        ProductDto value = loadFromSource(id);
        if (value != null) {
            long jitter = ThreadLocalRandom.current().nextLong(60);          // ±60 s
            redis.opsForValue().set(key, mapper.writeValueAsString(value),
                BASE_TTL.plusSeconds(jitter));
        }
        return value;
    }
}
```

### Distributed stampede guard (Redisson, cross-node)

```java
// Use when sync=true isn't enough: multiple app instances, non-Spring callers.
public UserDto getWithLock(String id) {
    String cacheKey = "users::" + id;          // matches Spring's default key format
    UserDto cached = cacheManager.getCache("users").get(id, UserDto.class);
    if (cached != null) return cached;

    RLock lock = redisson.getLock("cache-load:users:" + id);
    try {
        if (lock.tryLock(3, 10, TimeUnit.SECONDS)) {
            // Double-check after acquiring lock
            cached = cacheManager.getCache("users").get(id, UserDto.class);
            if (cached != null) return cached;
            UserDto fresh = repo.findById(id).map(UserDto::from).orElseThrow();
            cacheManager.getCache("users").put(id, fresh);
            return fresh;
        }
        throw new CacheLoadException("Could not acquire lock for user " + id);
    } catch (InterruptedException e) {
        Thread.currentThread().interrupt();
        throw new CacheLoadException("Interrupted waiting for lock", e);
    } finally {
        if (lock.isHeldByCurrentThread()) lock.unlock();
    }
}
```

---

## Anti-pattern

```java
// BAD — JDK serialization + infinite TTL + no namespace
@Bean
public RedisCacheManager badCacheManager(RedisConnectionFactory cf) {
    RedisCacheConfiguration bad = RedisCacheConfiguration.defaultCacheConfig();
    // ↑ no entryTtl → never expires
    // ↑ default serializer is JdkSerializationRedisSerializer
    return RedisCacheManager.builder(cf).cacheDefaults(bad).build();
}

// BAD — evict before commit; concurrent reader refills cache with stale DB row
@CacheEvict(cacheNames = "users", key = "#id", beforeInvocation = true)
@Transactional
public void delete(String id) { repo.deleteById(id); }

// BAD — custom SETNX lock (race: process dies between setNX and expire)
Boolean acquired = redis.opsForValue().setIfAbsent("lock:" + id, "1");
redis.expire("lock:" + id, 10, TimeUnit.SECONDS);   // not atomic
```

---

## Gotchas / version notes

- **Spring Boot 3.x auto-config**: a `RedisCacheConfiguration` bean overrides the global default; a `RedisCacheManagerBuilderCustomizer` bean adds per-cache config on top — prefer the customizer to avoid replacing auto-configured settings.
- **`sync = true` scope**: only guards within a single JVM. For multi-instance deployments use Redisson distributed lock (see above).
- **Key prefix**: Spring Boot adds `<cacheName>::` prefix by default (`useKeyPrefix = true`). Explicit `spring.cache.redis.key-prefix=myapp:` prepends before the cache name — resulting in `myapp:<cacheName>::<key>`.
- **`@CacheEvict` + `@Transactional`**: eviction fires after commit when `beforeInvocation = false` (default). If the transaction rolls back, the entry is NOT evicted — correct behaviour, but verify in integration tests.
- **`enableTimeToIdle()`** (Spring Data Redis 3.2+): resets TTL on each access (TTI semantics). Requires Redis 7.4+ `OBJECT IDLETIME` support; verify your Redis version before enabling.
- **`TtlFunction`** (Spring Data Redis 3.2+): compute TTL per cache entry (e.g., based on payload size or a field value) instead of a fixed `Duration`.
- **ObjectMapper for JSON serializer**: register `JavaTimeModule` and set `WRITE_DATES_AS_TIMESTAMPS = false`; otherwise `LocalDate`/`Instant` fields serialize incorrectly.
- **Lettuce vs Jedis**: Lettuce (default) is non-blocking and shares connections; Jedis uses a thread-per-connection pool. Lettuce is preferred for reactive stacks.
- **`@CachePut` does not read the cache** — it always invokes the method and writes the result. Never combine with `@Cacheable` on the same method.
