# Slice-test decision matrix (companion to `claudehut:review`)

## Web slice (MVC)
```java
@WebMvcTest(OrderController.class)
class OrderControllerTest {
  @Autowired MockMvc mvc;
  @MockBean OrderService service;   // collaborators mocked

  @Test void rejectsInvalidBody() throws Exception {
    mvc.perform(post("/orders").contentType(APPLICATION_JSON).content("{}"))
       .andExpect(status().isBadRequest());
  }
}
```

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
