# Container Lifecycle

## Singleton (recommended)

```java
@SpringBootTest
@Testcontainers
class MyIT {

    @Container
    static PostgreSQLContainer<?> postgres = new PostgreSQLContainer<>("postgres:16-alpine");

    // Spring boots once per test class. Container starts once per JVM (with reuse).
}
```

Container starts once, all tests in the class share it.

## Per-test (rare)

```java
@Container
PostgreSQLContainer<?> postgres = new PostgreSQLContainer<>("postgres:16-alpine");
// (non-static)
```

Container starts BEFORE each test, stops AFTER. Slow. Use only when test mutates infra state irreversibly.

## Multiple containers per class

```java
@Container
static PostgreSQLContainer<?> postgres = ...;
@Container
static GenericContainer<?> redis = new GenericContainer<>("redis:7-alpine").withExposedPorts(6379);
@Container
static KafkaContainer kafka = new KafkaContainer(DockerImageName.parse("confluentinc/cp-kafka:7.5.0"));
```

All start in parallel.

## Network sharing

For containers that need to talk to each other:

```java
static Network network = Network.newNetwork();

@Container
static PostgreSQLContainer<?> postgres = new PostgreSQLContainer<>("postgres:16-alpine")
    .withNetwork(network)
    .withNetworkAliases("db");

@Container
static GenericContainer<?> app = new GenericContainer<>("myapp:latest")
    .withNetwork(network)
    .withEnv("DB_URL", "jdbc:postgresql://db:5432/test");
```

## Shared across test classes (full singleton)

Initialize in static block, reuse:

```java
public abstract class IntegrationTestBase {

    static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:16-alpine")
        .withReuse(true);

    static {
        POSTGRES.start();
    }

    @DynamicPropertySource
    static void props(DynamicPropertyRegistry r) {
        r.add("spring.datasource.url", POSTGRES::getJdbcUrl);
        r.add("spring.datasource.username", POSTGRES::getUsername);
        r.add("spring.datasource.password", POSTGRES::getPassword);
    }
}

class UserIT extends IntegrationTestBase { ... }
class OrderIT extends IntegrationTestBase { ... }
```

## Cleanup

Singleton containers stay until JVM exits. For test isolation:

```java
@AfterEach
void cleanData() {
    jdbcTemplate.execute("TRUNCATE TABLE users CASCADE");
}
```

Or per-test transaction rollback (`@Transactional` on test class with Spring Boot).
