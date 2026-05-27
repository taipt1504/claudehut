---
name: redis-cache
description: Spring Data Redis conventions — caching with @Cacheable, key strategy, TTL/eviction policies, Redisson distributed lock patterns. Auto-loads when editing `**/*Cache*.java` or files using @Cacheable. Covers RedisTemplate config + serialization.
---

# Redis Cache

## Quick start (@Cacheable)

```java
@Service
@RequiredArgsConstructor
public class UserService {

    private final UserRepository repo;

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

## Config

```java
@Configuration
@EnableCaching
public class RedisConfig {

    @Bean
    public RedisCacheManager cacheManager(RedisConnectionFactory cf, ObjectMapper mapper) {
        RedisCacheConfiguration defaults = RedisCacheConfiguration.defaultCacheConfig()
            .entryTtl(Duration.ofMinutes(10))
            .disableCachingNullValues()
            .serializeKeysWith(RedisSerializationContext.SerializationPair.fromSerializer(new StringRedisSerializer()))
            .serializeValuesWith(RedisSerializationContext.SerializationPair.fromSerializer(
                new GenericJackson2JsonRedisSerializer(mapper)
            ));

        Map<String, RedisCacheConfiguration> cacheConfigs = Map.of(
            "users", defaults.entryTtl(Duration.ofMinutes(30)),
            "sessions", defaults.entryTtl(Duration.ofHours(24))
        );

        return RedisCacheManager.builder(cf)
            .cacheDefaults(defaults)
            .withInitialCacheConfigurations(cacheConfigs)
            .build();
    }
}
```

Detailed: `references/key-strategy.md`, `references/ttl-eviction.md`, `references/distributed-lock.md`.

## Assets

- `assets/templates/RedisConfig.java.tmpl`
- `assets/templates/DistributedLock.java.tmpl`

## Hard rules

- ALWAYS explicit TTL per cache namespace (no infinite cache).
- ALWAYS namespace keys with `value` (cache name).
- USE Redisson for distributed locks, NOT custom SETNX.
- USE JSON serializer (GenericJackson2JsonRedisSerializer) over JDK serialization (security).
- DO NOT cache mutable objects (defensively copy if needed).

## Exit criteria

- [ ] Cache TTL set per namespace
- [ ] Eviction policy chosen
- [ ] Key strategy avoids collisions
- [ ] Distributed lock uses Redisson if needed
