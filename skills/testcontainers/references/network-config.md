# Testcontainers Network Config

## Multi-container shared network

```java
static Network network = Network.newNetwork();

@Container
static PostgreSQLContainer<?> postgres = new PostgreSQLContainer<>("postgres:16-alpine")
    .withNetwork(network)
    .withNetworkAliases("db");

@Container
static GenericContainer<?> app = new GenericContainer<>("myapp:latest")
    .withNetwork(network)
    .withEnv("DB_URL", "jdbc:postgresql://db:5432/test")
    .dependsOn(postgres);
```

Containers communicate via alias hostname (`db`, not `localhost`).

## Exposed ports

```java
GenericContainer<?> redis = new GenericContainer<>("redis:7-alpine")
    .withExposedPorts(6379);

redis.start();
String host = redis.getHost();          // usually localhost
Integer port = redis.getMappedPort(6379); // random ephemeral port
```

Don't hardcode `6379` — port may collide with other tests.

## Fixed port (avoid)

```java
new GenericContainer<>("redis:7-alpine")
    .withFixedExposedPort(6379, 6379);  // ← BAD: collides on parallel tests
```

Only use for debugging via host tools, never in CI.

## Wait strategies

Default: wait for first listening port. For app readiness:

```java
new GenericContainer<>("myapp:latest")
    .withExposedPorts(8080)
    .waitingFor(Wait.forHttp("/actuator/health/readiness")
        .forStatusCode(200)
        .withStartupTimeout(Duration.ofSeconds(60)));
```

Other strategies:
- `Wait.forLogMessage(".*Started.*", 1)` — log regex
- `Wait.forListeningPort()` — TCP only
- `Wait.forHealthcheck()` — Docker HEALTHCHECK directive

## Spring auto-config (Boot 3.1+)

```java
@TestConfiguration
public class TestcontainersConfig {

    @Bean
    @ServiceConnection
    PostgreSQLContainer<?> postgres() {
        return new PostgreSQLContainer<>("postgres:16-alpine").withReuse(true);
    }

    @Bean
    @ServiceConnection(name = "redis")
    GenericContainer<?> redis() {
        return new GenericContainer<>("redis:7-alpine")
            .withExposedPorts(6379)
            .withReuse(true);
    }
}
```

Spring wires datasource URL automatically — no `@DynamicPropertySource` needed.

## CI considerations

- Docker socket must be available in CI runner (`/var/run/docker.sock`).
- Memory limit: large multi-container tests may OOM small runners (1-2 GB).
- Image pull: pre-pull common images in CI cache to avoid network delays.

## Network mode

Default: bridge network. Pods isolated.

For accessing host services:

```java
container.withExtraHost("host.docker.internal", "host-gateway");
```

Then container can reach host services via `host.docker.internal:<port>`.

## Anti-patterns

- Hardcoded port mappings → parallel collision
- Wait strategy too short → flaky on slow CI
- No wait strategy → race with container startup
- Network reuse across test classes without cleanup → leak
- Container not `static` (instance field) → start/stop per test → slow
