# ratelimit — summer-ratelimit-core, summer-ratelimit-autoconfigure
> Consumer-facing: yes · Auto-config: default-on · Depends on: core

## TL;DR
- Reactive distributed rate limiting for WebFlux; policyKey selects one of three strategies (fixed-window, sliding-window, token-bucket) per named policy.
- Auto-config is always on once the dependency is present (no enable/disable gate); default store is Redis (atomic Lua), fallback in-memory.
- `acquire(key)` errors with `ViewableException` (429) when denied; `tryAcquire(key)` returns a `RateLimitResult` you inspect.

## Activate
| Aspect | Value |
|---|---|
| Gradle | `implementation "io.f8a.summer:summer-ratelimit-autoconfigure"` (pulls `-core` via `api`) |
| Auto-config | `SummerRateLimitAutoConfiguration` (`@AutoConfiguration`, `@EnableConfigurationProperties(RateLimiterProperties.class)`) |
| Module gate | none — always contributes `RateLimitStore` + `RateLimiterService` (both `@ConditionalOnMissingBean`) when the jar is on the classpath |
| Store gate | `@ConditionalOnProperty(prefix="f8a.rate-limiter", name="storage-type", havingValue="redis", matchIfMissing=true)` + `@ConditionalOnClass(ReactiveStringRedisTemplate)` → `RedisRateLimitStore`; else `InMemoryRateLimitStore` (on by default = Redis) |

Note: default-on Redis requires a `ReactiveStringRedisTemplate` bean at runtime; set `storage-type: memory` for single-node/local without Redis.

## Config keys
| Key (`f8a.rate-limiter.`) | Default | Meaning |
|---|---|---|
| `key-prefix` | `ratelimit:` | Global prefix prepended to every store key |
| `storage-type` | `redis` | `redis` or `memory`; selects the store bean (see Activate) |
| `default-policy.strategy` | `token-bucket` (`TOKEN_BUCKET`) | Strategy used when a policyKey has no named policy |
| `default-policy.limit` | `100` | Max requests per window |
| `default-policy.window` | `60s` | Window `Duration` |
| `default-policy.token-bucket-refill-rate` | `0` | Tokens/sec; `0` = auto = `limit/windowSeconds`. TOKEN_BUCKET only |
| `policies.<policyKey>.{strategy,limit,window,token-bucket-refill-rate}` | — | Named policy; `<policyKey>` matched against `RateLimitKey.policyKey()` |

Strategy selection: `RateLimiterServiceImpl.resolvePolicy(policyKey)` → `getOrDefault(policies, policyKey, default-policy)`; the policy's `strategy` picks Fixed/Sliding/TokenBucket in `createLimiter`.

## Public API
| Type | When to use | Node |
|---|---|---|
| `RateLimiterService` | Inject to gate a reactive call by rate limit | `class:ratelimit/ratelimit-core/src/main/java/io/f8a/summer/core/ratelimit/RateLimiterService.java:RateLimiterService` |
| `RateLimitKey` | Build `(identifier, policyKey)`; identifier = user/IP/apiKey, policyKey selects policy | `class:ratelimit/ratelimit-core/src/main/java/io/f8a/summer/core/ratelimit/RateLimitKey.java:RateLimitKey` |
| `RateLimitResult` | Read `allowed/limit/remaining/resetAt` after `tryAcquire` | `class:ratelimit/ratelimit-core/src/main/java/io/f8a/summer/core/ratelimit/RateLimitResult.java:RateLimitResult` |
| `RateLimitStrategy` | Enum you set in a policy: `FIXED_WINDOW`/`SLIDING_WINDOW`/`TOKEN_BUCKET` | `class:ratelimit/ratelimit-core/src/main/java/io/f8a/summer/core/ratelimit/RateLimitStrategy.java:RateLimitStrategy` |
| `RateLimiterProperties` | Bind/read `f8a.rate-limiter.*` config | `class:ratelimit/ratelimit-core/src/main/java/io/f8a/summer/core/ratelimit/config/RateLimiterProperties.java:RateLimiterProperties` |
| `RateLimiter` | Implement a custom strategy (advanced) | `class:ratelimit/ratelimit-core/src/main/java/io/f8a/summer/core/ratelimit/RateLimiter.java:RateLimiter` |
| `RateLimitStore` | Declare your own bean to replace Redis/in-memory backend | `class:ratelimit/ratelimit-core/src/main/java/io/f8a/summer/core/ratelimit/store/RateLimitStore.java:RateLimitStore` |

Signatures: `Mono<RateLimitResult> tryAcquire(key)`; `tryAcquire(key, long limit, Duration window)`; `acquire(key)` (default); `acquire(key, limit, window)` (default); `Mono<Void> reset(key)`.

## Usage
```java
@RestController
@RequiredArgsConstructor
public class OrderController {
  private final RateLimiterService rateLimiterService;

  @PostMapping("/orders")
  public Mono<OrderResponse> create(@AuthenticationPrincipal String userId, @RequestBody CreateOrderRequest req) {
    RateLimitKey key = new RateLimitKey(userId, "orders:create"); // policyKey selects the policy
    return rateLimiterService.acquire(key)                        // errors 429 (ViewableException) if over limit
        .then(orderService.create(req));
  }
}
```
```yaml
f8a:
  rate-limiter:
    storage-type: redis          # default; use "memory" for single-node
    policies:
      "orders:create": { strategy: fixed-window, limit: 10, window: 60s }
```

## Gotchas
- No module on/off gate: the auto-config always runs when the jar is present; disable only by not depending on it, or override the beans.
- Store key = `key-prefix` + `policyKey:identifier` (`RateLimitKey.toStoreKey()`); empty/null policyKey → key is just `identifier`.
- `acquire(...)` emits `Mono.error(CommonExceptions.RATE_LIMIT_EXCEEDED.toException())` with detail values `limit` and `resetAt` (epoch seconds) → 429. Use `tryAcquire(...)` to inspect `RateLimitResult.allowed()` instead of erroring.
- Unmatched or null policyKey silently falls back to `default-policy` (`resolvePolicy`); a typo'd policyKey is NOT an error.
- Strategy is fixed at first use per policyKey: `RateLimiterServiceImpl` caches one `RateLimiter` per policyKey in a `ConcurrentHashMap`; changing a policy's strategy needs a restart.
- `tryAcquire(key, limit, window)` overload uses policyKey only to pick the strategy; the passed `limit`/`window` override the policy's numeric limits for that call.
- `token-bucket-refill-rate` applies to TOKEN_BUCKET only; bucket capacity (max burst) always equals `limit`; `0` auto-computes `limit/windowSeconds`.
- `storage-type: memory` (or absent `ReactiveStringRedisTemplate`) → `InMemoryRateLimitStore`: NOT shared across instances, unsafe behind >1 replica; entries expire lazily on access.
- Redis atomicity is per-op via Lua: fixed = `INCR`+`PEXPIRE`, sliding = `ZREMRANGEBYSCORE`/`ZADD`/`ZCARD`/`PEXPIRE`, token-bucket uses two keys (`<key>:tokens`, `<key>:refill`). `reset(key)` deletes `<key>`, `<key>:tokens`, `<key>:refill`.
- Override points: declare your own `RateLimitStore` or `RateLimiterService` bean (both `@ConditionalOnMissingBean`) to replace defaults.

## Graph refs
- `file:ratelimit/ratelimit-autoconfigure/src/main/java/io/f8a/summer/ratelimit/autoconfigure/SummerRateLimitAutoConfiguration.java`
- `file:ratelimit/ratelimit-autoconfigure/src/main/resources/META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports`
- `file:ratelimit/ratelimit-core/src/main/java/io/f8a/summer/core/ratelimit/RateLimiterService.java`
- `file:ratelimit/ratelimit-core/src/main/java/io/f8a/summer/core/ratelimit/service/RateLimiterServiceImpl.java`
- `file:ratelimit/ratelimit-core/src/main/java/io/f8a/summer/core/ratelimit/config/RateLimiterProperties.java`
- `file:ratelimit/ratelimit-core/src/main/java/io/f8a/summer/core/ratelimit/RateLimitKey.java`
- `file:ratelimit/ratelimit-core/src/main/java/io/f8a/summer/core/ratelimit/RateLimitResult.java`
- `file:ratelimit/ratelimit-core/src/main/java/io/f8a/summer/core/ratelimit/RateLimitStrategy.java`
- `file:ratelimit/ratelimit-core/src/main/java/io/f8a/summer/core/ratelimit/RateLimiter.java`
- `file:ratelimit/ratelimit-core/src/main/java/io/f8a/summer/core/ratelimit/store/RateLimitStore.java`
- `file:ratelimit/ratelimit-core/src/main/java/io/f8a/summer/core/ratelimit/store/RedisRateLimitStore.java`
- `file:ratelimit/ratelimit-core/src/main/java/io/f8a/summer/core/ratelimit/store/InMemoryRateLimitStore.java`
