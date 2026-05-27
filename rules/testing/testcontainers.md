---
id: rules/testing/testcontainers
paths:
  - "**/*IT.java"
severity: medium
tags: [testcontainers, integration-test]
---


# Testcontainers Rules

## DO

- Pin specific image tag (`postgres:16-alpine`).
- Use `static` field + `@Testcontainers` annotation for singleton lifecycle.
- Enable reuse: `withReuse(true)` + `~/.testcontainers.properties` `testcontainers.reuse.enable=true`.
- Use `@DynamicPropertySource` to inject container URL into Spring.
- Share container across test classes via base class.

## DON'T

- Use `latest` tag — non-reproducible.
- Start/stop container manually — `@Testcontainers` handles.
- Per-method container (`@Container` non-static) unless data isolation requires.
- Forget to clean test data between tests when sharing container.

## Reuse setup

```java
@Container
static PostgreSQLContainer<?> postgres = new PostgreSQLContainer<>("postgres:16-alpine")
    .withReuse(true);
```

User's `~/.testcontainers.properties`:

```
testcontainers.reuse.enable=true
```

Container persists across test runs — saves 2-3 seconds per startup.

## Data isolation

```java
@AfterEach
void truncate() {
    jdbcTemplate.execute("TRUNCATE TABLE users, orders CASCADE");
}
```

Or use `@Transactional` on test class for automatic rollback.

## Spring property injection

```java
@DynamicPropertySource
static void registerProps(DynamicPropertyRegistry r) {
    r.add("spring.datasource.url", postgres::getJdbcUrl);
    r.add("spring.datasource.username", postgres::getUsername);
    r.add("spring.datasource.password", postgres::getPassword);
}
```

Or use `@ServiceConnection` (Boot 3.1+):

```java
@TestConfiguration
public class TestcontainersConfig {
    @Bean
    @ServiceConnection
    PostgreSQLContainer<?> postgres() {
        return new PostgreSQLContainer<>("postgres:16-alpine").withReuse(true);
    }
}
```

## CI considerations

- Reuse may not be enabled in CI — container starts fresh per build.
- Docker socket must be available in CI runner.
- Memory limit: large containers may OOM small runners.

## Common containers

| Container | Image | Notes |
|-----------|-------|-------|
| PostgreSQL | `postgres:16-alpine` | Use Alpine for size |
| MySQL | `mysql:8` | |
| Redis | `redis:7-alpine` | `withExposedPorts(6379)` |
| Kafka | `confluentinc/cp-kafka:7.5.0` | KafkaContainer wrapper |
| LocalStack | `localstack/localstack:3` | AWS service emulator |
| Wiremock | `wiremock/wiremock:3` | HTTP stub server |

## Network sharing (multi-container)

```java
static Network network = Network.newNetwork();

@Container static PostgreSQLContainer<?> db = new PostgreSQLContainer<>("postgres:16-alpine")
    .withNetwork(network).withNetworkAliases("db");
@Container static GenericContainer<?> app = new GenericContainer<>("myapp:latest")
    .withNetwork(network).withEnv("DB_URL", "jdbc:postgresql://db:5432/test");
```

## Anti-patterns

- Sleeping after container.start() to "wait" — use `waitFor()` strategy.
- Reading port BEFORE container started — port assignment dynamic.
- Hardcoded port mapping (`withFixedExposedPort(5432, 5432)`) — collides on parallel runs.
- Container in non-static field — restarts every test.
