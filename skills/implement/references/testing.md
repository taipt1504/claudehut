# Java/Spring Testing Playbook

<!-- context7-researched best-practice playbook; preloaded by the implement skill at CREATE-time.
     Sources: JUnit 5 (/websites/junit_current), Testcontainers (/testcontainers/testcontainers-java),
     Spring Boot Test Slices (/websites/spring_io_spring-boot_3_4) via context7.
     Supplements skills/review/references/test-matrix.md (kept in review/). -->

**When:** `*Test.java`, `*IT.java`, choosing a test type, writing RED phase, reviewing test coverage.

---

## Cheapest-test decision matrix

| Scenario | Annotation | Speed | Infra |
|---|---|---|---|
| Pure domain / service logic | `@ExtendWith(MockitoExtension.class)` | Fast | None |
| Controller HTTP mapping, validation, security | `@WebMvcTest(Ctrl.class)` | Fast | Spring-web slice |
| WebFlux handler | `@WebFluxTest(Handler.class)` | Fast | Webflux slice |
| JPA queries, entity mapping | `@DataJpaTest` + TC | Slow-ish | DB container |
| R2DBC reactive persistence | `@DataR2dbcTest` + TC | Slow-ish | DB container |
| Outbound HTTP client | `@ExtendWith(MockitoExtension)` + WireMock | Medium | WireMock server |
| Kafka producer/consumer | TC `KafkaContainer` | Slow | Broker container |
| Full multi-layer flow | `@SpringBootTest` + TC | Slowest | All infra |

**Rule:** start at the narrowest slice; escalate to `@SpringBootTest` only when the behaviour genuinely spans layers (filter + security + controller interaction).

---

## DO

- **JUnit 5 Jupiter** — `org.junit.jupiter.api.*`; never JUnit 4.
- **AssertJ** — `assertThat(...)` everywhere; drop Hamcrest.
- **Naming** — `should<Expected>_when<Condition>` or `@DisplayName` sentence; never `test1`.
- **Structure** — one `// GIVEN / WHEN / THEN` block per test; one behaviour per test.
- **Grouping** — `@Nested` inner classes per feature/method; `@DisplayName` on the class.
- **Parameterized** — `@ParameterizedTest` + `@CsvSource` / `@MethodSource` / `@ValueSource` for data variants.
- **Mockito** — `@ExtendWith(MockitoExtension.class)` + `@Mock` / `@InjectMocks`; BDD style `given(...).willReturn(...)`.
- **Strict stubs** — `@MockitoSettings(strictness = Strictness.STRICT_STUBS)` (default Mockito 3+); fix unused stubs, don't downgrade.
- **ArgumentCaptor** — capture for complex object assertions instead of `any()` verify.
- **Spring MVC slices** — `@WebMvcTest` injects `MockMvcTester` (Boot 3.2+, AssertJ-native); `@MockitoBean` for collaborators.
- **Testcontainers** — pin image tag; `static` + `@Testcontainers`; `withReuse(true)` locally; `@ServiceConnection` (Boot 3.1+) over manual `@DynamicPropertySource`.
- **Data isolation** — `@AfterEach` TRUNCATE, or `@Transactional` for rollback.
- **WireMock** — dynamic port; stub narrowly; always `wm.verify(...)` afterward.
- **StepVerifier** — always terminate with `.verifyComplete()` or `.verify()`; use `withVirtualTime` for time operators.
- **Coverage** — line ≥ 80%, branch ≥ 70%; domain logic ≥ 95%; exclude generated mappers/DTOs.
- **Clock injection** — pass `Clock` to services; test time without PowerMock.
- **Awaitility** for async assertions — `await().atMost(5, SECONDS).untilAsserted(...)`.

## DON'T

- `Thread.sleep(...)` — use Awaitility or virtual time.
- Mock value objects (records, DTOs) or the system under test itself.
- Use `PowerMock` for static/final — refactor to inject the dependency.
- `@MockBean` (deprecated Boot 3.4+) — use `@MockitoBean` instead.
- Stub without using → `STRICT_STUBS` will catch it; fix the stub.
- Skip `.verifyComplete()` / `.verify()` on StepVerifier — test passes silently.
- `latest` image tag in Testcontainers — non-reproducible.
- Hardcode WireMock port — collides on parallel CI runs.
- `urlPathMatching(".*")` stub — too broad, masks wrong-URL bugs.
- `@Disabled` without a ticket reference comment.
- Test private methods directly — test via public surface.
- Coverage-padding tests that only assert "no exception thrown".

---

## Correct examples

### Unit — Mockito + BDD + ArgumentCaptor

```java
@ExtendWith(MockitoExtension.class)
class UserServiceTest {

    @Mock UserRepository repo;
    @Mock EventPublisher events;
    @InjectMocks UserService service;

    @Nested @DisplayName("create")
    class Create {
        @Test
        void shouldRejectDuplicate_whenEmailExists() {
            given(repo.existsByEmail("a@b.com")).willReturn(true);

            assertThatThrownBy(() -> service.create(new CreateUserRequest("a@b.com", "Alice")))
                .isInstanceOf(DuplicateUserException.class)
                .hasMessageContaining("a@b.com");
        }

        @Test
        void shouldPublishEvent_whenCreated() {
            given(repo.existsByEmail(any())).willReturn(false);
            given(repo.save(any())).thenAnswer(i -> i.getArgument(0));

            service.create(new CreateUserRequest("a@b.com", "Alice"));

            ArgumentCaptor<UserCreatedEvent> captor = ArgumentCaptor.forClass(UserCreatedEvent.class);
            verify(events).publish(captor.capture());
            assertThat(captor.getValue().email()).isEqualTo("a@b.com");
        }
    }

    @ParameterizedTest(name = "rejects email [{0}]")
    @ValueSource(strings = {"", " ", "no-at-sign", "@nodomain"})
    void shouldRejectInvalidEmail(String email) {
        assertThatThrownBy(() -> new EmailAddress(email))
            .isInstanceOf(IllegalArgumentException.class);
    }
}
```

### Web slice — @WebMvcTest + MockMvcTester (Boot 3.2+)

```java
@WebMvcTest(OrderController.class)
class OrderControllerTest {

    @Autowired MockMvcTester mvc;       // AssertJ-native; preferred over MockMvc in Boot 3.2+
    @MockitoBean OrderService service;  // @MockBean deprecated in Boot 3.4

    @Test
    void shouldReturn400_whenBodyMissing() {
        assertThat(mvc.post().uri("/orders").contentType(APPLICATION_JSON).content("{}"))
            .hasStatus(HttpStatus.BAD_REQUEST);
    }

    @Test
    void shouldReturn201_whenValid() {
        given(service.create(any())).willReturn(new OrderDto("o1"));
        assertThat(mvc.post().uri("/orders")
                .contentType(APPLICATION_JSON)
                .content("""{"item":"book","qty":1}"""))
            .hasStatus(HttpStatus.CREATED)
            .bodyJson().extractingPath("$.id").isEqualTo("o1");
    }
}
```

### Persistence slice — @DataJpaTest + Testcontainers + @ServiceConnection

```java
@DataJpaTest
@Testcontainers
@AutoConfigureTestDatabase(replace = NONE)   // disable in-memory H2; use real Postgres
class OrderRepositoryIT {

    @Container
    @ServiceConnection                         // Boot 3.1+: auto-wires datasource props
    static PostgreSQLContainer<?> postgres =
        new PostgreSQLContainer<>("postgres:16-alpine").withReuse(true);

    @Autowired OrderRepository repo;

    @AfterEach
    void truncate(@Autowired JdbcTemplate jdbc) {
        jdbc.execute("TRUNCATE orders CASCADE");
    }

    @Test
    void shouldPersistAndRetrieve() {
        Order saved = repo.save(new Order(null, "book", 2));
        assertThat(saved.id()).isNotNull();
        assertThat(repo.findById(saved.id())).isPresent();
    }
}
```

### Outbound HTTP — WireMock extension

```java
@ExtendWith(WireMockExtension.class)
class PaymentClientTest {

    @RegisterExtension
    static WireMockExtension wm = WireMockExtension.newInstance()
        .options(wireMockConfig().dynamicPort())
        .build();

    PaymentClient client;

    @BeforeEach
    void setUp() {
        client = new PaymentClient("http://localhost:" + wm.getPort());
    }

    @Test
    void shouldCharge_andReturnId() {
        wm.stubFor(post("/v1/charges")
            .withRequestBody(matchingJsonPath("$.amount", equalTo("1000")))
            .willReturn(ok()
                .withHeader("Content-Type", "application/json")
                .withBody("""{"id":"ch_123","status":"succeeded"}""")));

        ChargeResult result = client.charge(new ChargeRequest(1000));

        assertThat(result.id()).isEqualTo("ch_123");
        wm.verify(postRequestedFor(urlEqualTo("/v1/charges")));
    }

    @Test
    void shouldRetry_onTransientFailure() {
        wm.stubFor(post("/v1/charges")
            .inScenario("retry").whenScenarioStateIs(STARTED)
            .willReturn(serverError()).willSetStateTo("ok"));
        wm.stubFor(post("/v1/charges")
            .inScenario("retry").whenScenarioStateIs("ok")
            .willReturn(ok().withBody("""{"id":"ch_456"}""")));

        ChargeResult result = client.chargeWithRetry(new ChargeRequest(500));

        assertThat(result.id()).isEqualTo("ch_456");
    }
}
```

### Reactive — StepVerifier (success / error / virtual time / context)

```java
@ExtendWith(MockitoExtension.class)
class UserHandlerTest {

    @Mock UserRepository repo;
    @InjectMocks UserHandler handler;

    @Test
    void shouldEmitUser_whenFound() {
        given(repo.findById("u1")).willReturn(Mono.just(new User("u1", "alice@x.com")));

        StepVerifier.create(handler.findById("u1"))
            .assertNext(u -> assertThat(u.email()).isEqualTo("alice@x.com"))
            .verifyComplete();                          // MUST terminate; silent pass without it
    }

    @Test
    void shouldEmitError_whenNotFound() {
        given(repo.findById("missing")).willReturn(Mono.empty());

        StepVerifier.create(handler.findById("missing"))
            .expectError(UserNotFoundException.class)
            .verify();
    }

    @Test
    void shouldRetry_with2sBackoff() {
        given(repo.findById("u1"))
            .willReturn(Mono.error(new RuntimeException("transient")),
                        Mono.just(new User("u1", "alice@x.com")));

        StepVerifier.withVirtualTime(() ->
                handler.findByIdWithRetry("u1")
                       .retryWhen(Retry.backoff(1, Duration.ofSeconds(2))))
            .expectSubscription()
            .expectNoEvent(Duration.ofSeconds(2))
            .assertNext(u -> assertThat(u.id()).isEqualTo("u1"))
            .verifyComplete();
    }

    @Test
    void shouldUseRequestContext() {
        StepVerifier.create(
                handler.process().contextWrite(Context.of("tenantId", "t1")))
            .expectNextMatches(r -> r.tenant().equals("t1"))
            .verifyComplete();
    }
}
```

---

## Anti-patterns

```java
// BAD: Thread.sleep — flaky, slow
Thread.sleep(2000);
assertThat(repo.count()).isEqualTo(1);

// GOOD: Awaitility
await().atMost(5, SECONDS).untilAsserted(() -> assertThat(repo.count()).isEqualTo(1));

// BAD: StepVerifier missing terminal — test always passes
StepVerifier.create(service.findAll())
    .assertNext(u -> assertThat(u.id()).isNotNull());
// missing .verifyComplete()!

// BAD: @SpringBootTest for a pure controller concern
@SpringBootTest   // loads entire context — 10× slower than @WebMvcTest

// BAD: non-static container — restarts every test method
@Container
PostgreSQLContainer<?> db = new PostgreSQLContainer<>("postgres:16-alpine");

// GOOD: static singleton
@Container
static PostgreSQLContainer<?> db = new PostgreSQLContainer<>("postgres:16-alpine").withReuse(true);

// BAD: @MockBean (deprecated Boot 3.4)
@MockBean OrderService service;

// GOOD
@MockitoBean OrderService service;
```

---

## Gotchas / version notes

| Version | Change |
|---|---|
| Spring Boot 3.1 | `@ServiceConnection` replaces `@DynamicPropertySource` for TC containers |
| Spring Boot 3.2 | `MockMvcTester` (AssertJ-native) preferred over `MockMvc` for new tests |
| Spring Boot 3.4 | `@MockBean` / `@SpyBean` deprecated → use `@MockitoBean` / `@SpyitoBean` |
| Mockito 3+ | `STRICT_STUBS` is default; unused stubs throw `UnnecessaryStubbingException` |
| Testcontainers 1.20+ | `withReuse(true)` requires `testcontainers.reuse.enable=true` in `~/.testcontainers.properties`; ignored in CI unless explicitly set |
| JUnit 5.11+ | `@ParameterizedTest` constants moved to `ParameterizedInvocationConstants`; old ones deprecated |
| JaCoCo | Exclude `*MapperImpl`, `*Application`, `*.dto.*`, `*.config.*` from coverage; domain ≥ 95%, services ≥ 85%, overall ≥ 80% line / 70% branch |
| WireMock 3.x | Use `WireMockExtension` (JUnit 5 native); `wiremock-spring-boot` starter for slice integration |
| R2DBC | `@DataR2dbcTest` does NOT use embedded H2 by default — always pair with TC container |

**Never** load `@SpringBootTest` just to get a bean you could mock. Context startup is 5–30× slower than a slice.
