---
id: rules/framework/redis
applies-to: "**/*Redis*.java, **/*Cache*.java"
stack-signal: "cache=redis"
severity: medium
tags: [redis, cache, distributed-lock]
---

# Redis Rules

## DO

- Use JSON serializer (`GenericJackson2JsonRedisSerializer`) not JDK serialization.
- Explicit TTL per cache namespace.
- Namespace keys: `<service>:<entity>:<id>`.
- Use Redisson for distributed locks (not custom SETNX).
- Pool: configure max-active, max-idle.

## DON'T

- JDK serialization (deprecated, insecure, brittle).
- Infinite TTL.
- Cache mutable objects without defensive copy.
- Custom SETNX for locks — race conditions.
- Keys without namespace — collisions.

## Configuration

```java
@Configuration
@EnableCaching
public class RedisConfig {

    @Bean
    public RedisCacheManager cacheManager(RedisConnectionFactory cf, ObjectMapper mapper) {
        RedisCacheConfiguration defaults = RedisCacheConfiguration.defaultCacheConfig()
            .entryTtl(Duration.ofMinutes(10))
            .disableCachingNullValues()
            .serializeValuesWith(SerializationPair.fromSerializer(
                new GenericJackson2JsonRedisSerializer(mapper)));
        return RedisCacheManager.builder(cf).cacheDefaults(defaults).build();
    }
}
```

## Distributed lock (Redisson)

```java
RLock lock = redisson.getLock("order-process:" + orderId);
try {
    if (lock.tryLock(5, 30, TimeUnit.SECONDS)) {
        return doProcess(orderId);
    }
    throw new LockAcquisitionException(orderId);
} finally {
    if (lock.isHeldByCurrentThread()) lock.unlock();
}
```

## Anti-patterns

```java
// BAD — custom SETNX lock (race conditions)
Boolean acquired = redis.setNX(key, "1");
redis.expire(key, 30, TimeUnit.SECONDS);  // race: process dies between setNX and expire

// BAD — JDK serialization
template.setValueSerializer(new JdkSerializationRedisSerializer());

// BAD — infinite TTL
@Cacheable(value = "users", key = "#id")  // no TTL config → never expires
```

## References

- See `claudehut:redis-cache` skill.
- Distributed lock patterns: `claudehut:redis-cache/references/distributed-lock.md`.
