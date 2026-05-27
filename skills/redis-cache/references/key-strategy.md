# Redis Key Strategy

## Naming

Pattern: `<service>:<entity>:<id>[:<field>]`

- `user-svc:user:123` — entity by ID
- `user-svc:user:123:sessions` — entity's collection
- `user-svc:user:by-email:alice@b.com` — secondary lookup
- `rate-limit:ip:10.0.0.1` — rate counter

Lowercase, colon-separated, no spaces. Avoid magic abbreviations.

## Namespacing

- Always prefix with service name. Prevents cross-service collisions in shared Redis.
- Use Spring `@Cacheable(value = "users", key = "#id")` — `value` becomes the namespace.

## Cardinality

| Key pattern | Cardinality | Caution |
|-------------|-------------|---------|
| `user:<id>` | 1 per user (OK) | – |
| `user:<id>:<field>` | N per user | bounded |
| `user:<id>:event:<ts>` | unbounded | needs TTL + cap |

Unbounded keys → memory blowup. Always pair with TTL + LRU eviction.

## Composite keys

```java
@Cacheable(value = "purchase", key = "{#tenantId, #userId}")
public PurchaseHistory get(String tenantId, String userId) { ... }
```

Generates key `purchase::tenant1-user42` (Spring serializes SpEL list).

## Anti-patterns

- Key from mutable object — cache miss after object change.
- Long keys (> 200 bytes) — wasted memory at scale.
- Hash of complex object as key — collision risk; use natural key.
- Trailing/leading spaces in key — silent miss.
