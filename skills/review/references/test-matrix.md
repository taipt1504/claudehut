# Slice-test decision matrix (companion to `claudehut:review`)

## Web slice (MVC)
```java
@WebMvcTest(OrderController.class)
class OrderControllerTest {
  @Autowired MockMvcTester mvc;      // Boot 3.4+, AssertJ-native; MockMvc on older
  @MockitoBean OrderService service; // collaborators mocked (@MockBean is removed in Boot 4)

  @Test void rejectsInvalidBody() throws Exception {
    mvc.perform(post("/orders").contentType(APPLICATION_JSON).content("{}"))
       .andExpect(status().isBadRequest());
  }
}
```

## Web slice (WebFlux)
```java
@WebFluxTest(OrderHandler.class)
class OrderHandlerTest {
  @Autowired WebTestClient client;
  @MockitoBean OrderService service;

  @Test void rejectsInvalidBody() {
    client.post().uri("/orders").bodyValue("{}")
          .exchange().expectStatus().isBadRequest();
  }
}
```

## Reactive persistence slice (R2DBC) + Testcontainers
```java
@DataR2dbcTest
@Testcontainers
class OrderRepositoryIT {
  @Container static PostgreSQLContainer<?> db = new PostgreSQLContainer<>("postgres:16");
  @DynamicPropertySource static void props(DynamicPropertyRegistry r) {
    r.add("spring.r2dbc.url", () -> "r2dbc:postgresql://%s:%d/%s"
        .formatted(db.getHost(), db.getFirstMappedPort(), db.getDatabaseName()));
    r.add("spring.r2dbc.username", db::getUsername);
    r.add("spring.r2dbc.password", db::getPassword);
  }
  @Autowired OrderRepository repo;
  @Test void persists() {
    StepVerifier.create(repo.save(new Order("o1")))
                .assertNext(o -> assertThat(o.id()).isNotNull())
                .verifyComplete();
  }
}
```

**Assert reactive chains with `StepVerifier`, never `.block()` in a test** — blocking hides the
scheduler and passes on a chain that would deadlock under load. Time-based operators get
`StepVerifier.withVirtualTime`, not `Thread.sleep`.

**Testcontainers, not embedded fakes.** H2 in Postgres-compatibility mode, embedded Redis and
embedded Kafka all diverge from the real engine exactly where the bugs are: locking semantics,
`SKIP LOCKED`, JSONB, consumer-group rebalance. A green test against a fake is not evidence.

## Persistence slice + Testcontainers
```java
@DataJpaTest
@Testcontainers
class OrderRepositoryIT {
  @Container static PostgreSQLContainer<?> db = new PostgreSQLContainer<>("postgres:16");
  @DynamicPropertySource static void props(DynamicPropertyRegistry r) {
    r.add("spring.datasource.url", db::getJdbcUrl);
    r.add("spring.datasource.username", db::getUsername);
    r.add("spring.datasource.password", db::getPassword);
  }
  @Autowired OrderRepository repo;
  @Test void persists() { assertThat(repo.save(new Order("o1")).id()).isNotNull(); }
}
```

## Outbound HTTP with WireMock
```java
wireMock.stubFor(get("/rates").willReturn(okJson("{\"usd\":1.0}")));
// ... call code under test ...
wireMock.verify(getRequestedFor(urlEqualTo("/rates")));
```

## Async without sleep
```java
await().atMost(5, SECONDS).untilAsserted(() -> assertThat(repo.count()).isEqualTo(1));
```

## Choosing
- Start at the narrowest slice that exercises the change. Escalate to `@SpringBootTest` only when the
  behavior genuinely spans layers (e.g. a filter + security + controller interaction).
- Black-box tests drive the running app over HTTP (RestAssured / `WebTestClient`) against Testcontainers
  infra — reserve for end-to-end acceptance of a feature.
