---
id: rules/testing/testcontainers
paths:
  - "**/*IT.java"
  - "**/*IntegrationTest*.java"
  - "**/TestcontainersConfig.java"
severity: medium
stack: "test=testcontainers"
tags: [testcontainers, integration-test, spring-boot]
---
<!-- ClaudeHut rule template — generated into .claude/rules/testing/testcontainers.md by claudehut-init. Reused & enhanced from committed rules/testing/testcontainers.md. -->


# Testcontainers Rules

## DO

- Pin specific image tag (`postgres:16-alpine`).
- Use `@ServiceConnection` (Boot 3.1+) — replaces `@DynamicPropertySource` boilerplate in one annotation.
- Prefer singleton container via `static` field + abstract base class for suites > 3 classes.
- Enable reuse for local dev: `withReuse(true)` + `~/.testcontainers.properties` `testcontainers.reuse.enable=true`.
- Always read port via `container.getMappedPort(5432)` — never assume host port.

## DON'T

- Use `latest` tag — non-reproducible.
- Start/stop containers manually — lifecycle is managed.
- Use non-static `@Container` field unless data isolation per-test is explicitly required.
- Enable container reuse in CI — see reuse section.
- Set `TESTCONTAINERS_RYUK_DISABLED=true` on shared/persistent CI runners — leaks containers.

## @ServiceConnection vs @DynamicPropertySource (Boot 3.1+)

Prefer `@ServiceConnection` — zero boilerplate, Boot auto-wires all datasource/kafka/redis properties. Legacy `@DynamicPropertySource` still works but requires manual property wiring.

```java
@TestConfiguration(proxyBeanMethods = false)
public class TestcontainersConfig {

    @Bean
    @ServiceConnection                          // Boot 3.1+ — replaces @DynamicPropertySource
    PostgreSQLContainer<?> postgres() {
        return new PostgreSQLContainer<>("postgres:16-alpine");
    }
    @Bean
    @ServiceConnection
    KafkaContainer kafka() {
        return new KafkaContainer(DockerImageName.parse("confluentinc/cp-kafka:7.5.0"));
    }
}
```

## Lifecycle strategy — decision table

| Scenario | Pattern | Rationale |
|---|---|---|
| Single test class | `@Testcontainers` + `static @Container` | Simple, Ryuk cleans up |
| Integration suite ≤ 3 classes | `@Testcontainers` + `static @Container` per class | Startup cost acceptable |
| Integration suite **> 3 classes** | **Singleton via abstract base class** | One start/stop for entire suite |
| Data-isolation required per test | Non-static `@Container` (restart per test) | Explicit choice, document why |

### Singleton pattern (suite > 3 classes)

```java
// Container starts once on class load; Ryuk stops it at JVM exit
public abstract class AbstractIntegrationTest {
    static final PostgreSQLContainer<?> POSTGRES =
        new PostgreSQLContainer<>("postgres:16-alpine");
    static { POSTGRES.start(); }
}

@SpringBootTest
class OrderServiceIT extends AbstractIntegrationTest { ... }   // no @Testcontainers needed
```

## Container reuse across runs (local dev only)

Add `.withReuse(true)` to the container bean and set `testcontainers.reuse.enable=true` in `~/.testcontainers.properties`.

**Why not in CI:** a reused container carries stale schema/data, and config-hash drift silently reuses a mismatched container — "green locally, broken in CI."

**Rule:** commit `.withReuse(false)` (default) or guard with an env var:
```java
.withReuse(!"true".equals(System.getenv("CI")))
```

## Ryuk in CI — when to disable

| CI runner type | `TESTCONTAINERS_RYUK_DISABLED` | Why |
|---|---|---|
| Ephemeral (GH Actions, fresh VM per build) | `true` — safe | Runner is destroyed; Ryuk overhead not needed |
| Shared / long-lived runner | **never** | Without Ryuk, containers accumulate → OOM / port exhaustion |
| Docker-in-Docker (DinD) | `true` — usually safe | DinD daemon dies with the job |

On GH Actions set `TESTCONTAINERS_RYUK_DISABLED: "true"` in the job `env`.

## Parallel test execution

One container instance per JVM fork — never share across forks (no shared state, no port conflicts).

```groovy
// build.gradle
test {
    maxParallelForks = Runtime.runtime.availableProcessors().intdiv(2) ?: 1
}
```

**Dynamic-port rule (mandatory):** always resolve host port at runtime — `withFixedExposedPort` causes `BindException: Address already in use` on parallel forks (fails in CI, hard to reproduce locally).

```java
String url = "jdbc:postgresql://" + postgres.getHost()
           + ":" + postgres.getMappedPort(5432) + "/test";
```

## Data isolation

```java
@AfterEach
void truncate() {
    jdbcTemplate.execute("TRUNCATE TABLE users, orders CASCADE");
}
```

Or `@Transactional` on the test class for automatic rollback (does not work when the code under test starts its own transaction).

## Common containers

| Container | Image | Notes |
|-----------|-------|-------|
| PostgreSQL | `postgres:16-alpine` | `@ServiceConnection` supported |
| MySQL | `mysql:8` | `@ServiceConnection` supported |
| Redis | `redis:7-alpine` | `@ServiceConnection` supported |
| Kafka | `confluentinc/cp-kafka:7.5.0` | `KafkaContainer`; `@ServiceConnection` supported |
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

| Anti-pattern | Failure mode |
|---|---|
| `Thread.sleep()` after `start()` | Flaky — race on slow CI; use `waitingFor(Wait.forListeningPort())` |
| Read port before container started | `IllegalStateException` at bind time |
| `withFixedExposedPort` | `BindException` on parallel forks |
| Non-static `@Container` without intent | Container restarts every test — 3-5 s penalty each |
| `TESTCONTAINERS_RYUK_DISABLED` on shared runner | Container leak → OOM / port exhaustion on runner |
| Reuse enabled in CI | Stale schema/data → false green or false red |
