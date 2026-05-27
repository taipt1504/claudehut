# Container Reuse Flag

## Goal

Reuse the same container across test runs (within JVM lifetime + across JVMs) for fast feedback.

Without reuse: each `mvn test` / `./gradlew test` starts fresh container (2-5s overhead).
With reuse: container persists; subsequent runs reuse instantly.

## Enable in test code

```java
@Container
static PostgreSQLContainer<?> postgres = new PostgreSQLContainer<>("postgres:16-alpine")
    .withReuse(true);
```

## Enable globally

User-level `~/.testcontainers.properties`:

```properties
testcontainers.reuse.enable=true
```

Without this property, `withReuse(true)` is ignored (security default).

## How reuse works

Testcontainers computes a hash of (image + env + ports + cmd) and labels the container with it. Next run with same hash → reuse existing container.

If you change ANY config (env var, exposed port), hash differs → new container.

## CI

In CI: typically DISABLE reuse — each build should start fresh. Set:

```properties
testcontainers.reuse.enable=false
```

Or simply don't include the property; default is false.

## Cleanup

```bash
docker ps -a --filter "label=org.testcontainers=true"
docker container prune --filter "label=org.testcontainers=true"
```

## Data isolation with reuse

Reused container retains state from previous run. Always reset data between tests:

```java
@AfterEach
void truncate() {
    jdbcTemplate.execute("TRUNCATE TABLE users, orders CASCADE");
}
```

Or use `@Transactional` rollback per test (Spring).

## Anti-patterns

- `withReuse(true)` without `~/.testcontainers.properties` → silently ignored
- Reuse in CI → tests start dirty
- Reuse without data cleanup → cross-test pollution
- Reuse with non-deterministic config (random ports in code) → cache miss
