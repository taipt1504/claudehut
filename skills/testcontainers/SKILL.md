---
name: testcontainers
description: Testcontainers for Java integration tests — singleton vs per-class lifecycle, reuse flag, network sharing, Postgres/Kafka/Redis containers, dynamic Spring properties. Auto-loads when editing `**/*IT.java`, `src/integrationTest/**/*.java`.
---

# Testcontainers

Real infrastructure in tests via Docker.

## Quick start (Postgres)

```java
@SpringBootTest
@Testcontainers
class UserRepositoryIT {

    @Container
    static PostgreSQLContainer<?> postgres = new PostgreSQLContainer<>("postgres:16-alpine")
        .withReuse(true);

    @DynamicPropertySource
    static void postgresProps(DynamicPropertyRegistry registry) {
        registry.add("spring.datasource.url", postgres::getJdbcUrl);
        registry.add("spring.datasource.username", postgres::getUsername);
        registry.add("spring.datasource.password", postgres::getPassword);
    }

    @Autowired UserRepository repo;

    @Test
    void shouldPersistAndRetrieve() {
        User saved = repo.save(new User(null, "a@b.com", "Alice"));
        Optional<User> found = repo.findById(saved.id());
        assertThat(found).hasValue(saved);
    }
}
```

Detailed: `references/lifecycle.md`, `references/network-config.md`, `references/reuse-flag.md`.

## Assets

- `assets/templates/IntegrationTest.java.tmpl`
- `assets/templates/TestcontainersConfig.java.tmpl`

## Hard rules

- USE singleton (static) container per test class for performance.
- USE `withReuse(true)` + `~/.testcontainers.properties testcontainers.reuse.enable=true` for fast iteration.
- USE `@DynamicPropertySource` to inject container URLs into Spring context.
- USE specific image tags (`postgres:16-alpine`, not `postgres:latest`).
- DO NOT manually `start()`/`stop()` — `@Testcontainers` does this.

## Exit criteria

- [ ] Container as `static` field
- [ ] `@DynamicPropertySource` configures Spring
- [ ] Specific image tag pinned
- [ ] Reuse flag enabled if local dev
