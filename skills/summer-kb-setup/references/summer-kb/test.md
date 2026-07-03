# test — summer-test
> Consumer-facing: yes · Auto-config: test-scope · Depends on: core

## TL;DR
- TEST-scope utility library: WireMock stub servers + JSON-defined HTTP test cases + configurable JSON comparator; also bundles Testcontainers Postgres helpers.
- No `AutoConfiguration.imports`, no beans, no `@ConditionalOn*` gate — adding the dep does nothing until you instantiate `WireMockServiceManager` and call the `StubConfigurationUtils` lifecycle.
- Config is blackbox JSON (`blackbox_config.json` + test-case files), not `@ConfigurationProperties`; paths overridable via system properties.

## Activate
| | |
|---|---|
| Gradle coordinate | `testImplementation "io.f8a.summer:summer-test"` |
| AutoConfiguration | None — plain test-utility library, no starter |
| Gate property | None — activation is manual (instantiate + call lifecycle) |

Pulls in transitively via `api` (`test/build.gradle`): WireMock standalone, jakarta servlet-api, jakarta persistence-api, JUnit 5 (api/params/engine), Testcontainers (junit-jupiter + postgresql), Flyway (core + postgresql), postgresql driver, r2dbc-postgresql, spring-r2dbc, json-path, json-unit-assertj, json-schema-validator, hamcrest, spring-boot-starter-webflux. Depends on `summer-core`.

## Config keys
None — types/utilities only. Behavior is driven by blackbox JSON, not `@ConfigurationProperties`. Two system properties override the default file locations (read in your JUnit driver, see `BlackboxTest`):

| System property | Default | Meaning |
|---|---|---|
| `blackbox.config.path` | `src/test/resources/blackbox/blackbox_config.json` | blackbox config file |
| `blackbox.test.cases.root` | `src/test/resources/blackbox/test-cases` | test-case scan root |

## Public API
| Type | Kind | When to use | Graph node id |
|---|---|---|---|
| `WireMockServiceManager` | class | Start/stop/reset stub servers; resolve base URLs | `class:test/src/main/java/io/f8a/summer/test/wiremock/WireMockServiceManager.java:WireMockServiceManager` |
| `StubConfigurationUtils` | static utils | Load config + `startAllStubServices` / `waitForServicesReady` / `resetAllStubs` lifecycle | `class:test/src/main/java/io/f8a/summer/test/utils/StubConfigurationUtils.java:StubConfigurationUtils` |
| `TestCaseUtils` (+ `TestCaseInfo`) | static utils | Scan/parse/validate JSON test cases, group by service | `class:test/src/main/java/io/f8a/summer/test/utils/TestCaseUtils.java:TestCaseUtils` |
| `TestExecutionUtils` | static utils | Execute one test case: `executeBlackboxTestCase(serviceManager, testCase)` | `class:test/src/main/java/io/f8a/summer/test/utils/TestExecutionUtils.java:TestExecutionUtils` |
| `WireMockStubUtils` | static utils | Programmatic stub creation helpers | `class:test/src/main/java/io/f8a/summer/test/wiremock/WireMockStubUtils.java:WireMockStubUtils` |
| `BlackboxTestConfig` / `StubsConfig` / `ServiceConfig` | JSON POJOs | Mapped from `blackbox_config.json`; read `getStubs()` / `getServices()` | `class:test/src/main/java/io/f8a/summer/test/config/BlackboxTestConfig.java:BlackboxTestConfig` |
| `ComparisonConfig` (+ `Builder`) | JSON POJO | Configure JSON comparison (ignore fields, array order, strict mode) | `class:test/src/main/java/io/f8a/summer/test/comparison/ComparisonConfig.java:ComparisonConfig` |
| `BlackboxTestRunner` / `StubsOnlyRunner` | class | Programmatic runner, alternative to the JUnit `@TestFactory` wiring | `class:test/src/main/java/io/f8a/summer/test/runner/BlackboxTestRunner.java:BlackboxTestRunner` |
| `PostgresTestContainer` / `DatabaseTestUtils` | class | Testcontainers Postgres for integration tests | `class:test/src/main/java/io/f8a/summer/test/database/PostgresTestContainer.java:PostgresTestContainer` |

Reference implementation (framework's OWN test — copy this pattern, NOT a consumer entry point): `test/src/test/java/io/f8a/test/wiremock/BlackboxTest.java`.

## Usage
```java
// @BeforeAll — load, start, wait
WireMockServiceManager serviceManager = new WireMockServiceManager();
BlackboxTestConfig cfg = StubConfigurationUtils.loadBlackboxConfiguration(CONFIG_PATH);
StubConfigurationUtils.startAllStubServices(serviceManager, cfg.getStubs());
StubConfigurationUtils.waitForServicesReady(serviceManager, 30);

// @TestFactory over scanned cases
List<TestCaseInfo> cases = TestCaseUtils.scanTestCasesRecursively(TEST_CASES_ROOT);
// per case: TestExecutionUtils.executeBlackboxTestCase(serviceManager, testCase);

// @BeforeEach: StubConfigurationUtils.resetAllStubs(serviceManager);
// @AfterAll:   serviceManager.stopAllServers();
```
`blackbox_config.json` shape: `{ "stubs": { "services": [ { "name", "port", "stubs_data_path", "enabled":true, "logging" } ] }, "test_cases": { "root_path", "file_patterns", "timeout_seconds":30, "recursive_scan":true } }`. Stub layout under `stubs_data_path` MUST be `mappings/` + `__files/` (WireMock 3.x). See `stubs-guideline.md`.

## Gotchas
- No auto-wiring: adding the dep does nothing. You must instantiate `WireMockServiceManager` and drive the `StubConfigurationUtils` lifecycle (or use `BlackboxTestRunner`).
- `startService` throws `IllegalArgumentException` if `stubs_data_path` does not exist or is not a directory — create it before start.
- Fixed ports: `ServiceConfig.port` is a concrete port, not random; collisions across services/parallel runs are on you. `getWireMockBaseUrl` returns `http://localhost:<port>`.
- Startup timing: `startService` sleeps 500ms then checks `isRunning()` (throws if not); `waitForServicesReady(timeoutSeconds)` polls every 100ms — pass a generous timeout (example uses 30).
- `startAllStubServices` throws `IllegalStateException("No stub services configured")` when the stubs config or its `services` list is null (an empty list does not throw — no servers start); `waitForServicesReady` throws `IllegalStateException` if not all ready within timeout.
- Test-case validation (`TestCaseUtils.validateTestCaseStructure`) hard-requires `name`, `test`, `test.request` with `method`+`url`, and `assertions.status`; missing any throws `IllegalArgumentException`. Multi-case files wrap `testCases: [...]`.
- `extractServiceFromPath` has hard-coded demo names (`user-service`, `payment-service`, `notification-service`, `order-service`, `inventory-service`, `auth-service`), then falls back to any path segment ending in `-service` — name test-case dirs `<x>-service` for correct grouping.
- `TestExecutionUtils.executeHttpRequest` supports GET/POST/PUT/DELETE only; other methods throw `IllegalArgumentException("Unsupported HTTP method: " + method)`.
- `ComparisonConfig` defaults: `strict_mode=true`, `allow_extra_fields=false` — extra fields in the actual response fail unless you set `allow_extra_fields` / `ignore_fields`.
- Reset stubs `@BeforeEach` via `StubConfigurationUtils.resetAllStubs(...)` to avoid cross-test stub bleed.
- TEST scope only — never leak these onto the main/runtime classpath.

## Graph refs
- `file:test/build.gradle`
- `file:test/src/main/java/io/f8a/summer/test/wiremock/WireMockServiceManager.java`
- `file:test/src/main/java/io/f8a/summer/test/wiremock/WireMockStubUtils.java`
- `file:test/src/main/java/io/f8a/summer/test/utils/StubConfigurationUtils.java`
- `file:test/src/main/java/io/f8a/summer/test/utils/TestCaseUtils.java`
- `file:test/src/main/java/io/f8a/summer/test/utils/TestExecutionUtils.java`
- `file:test/src/main/java/io/f8a/summer/test/config/BlackboxTestConfig.java`
- `file:test/src/main/java/io/f8a/summer/test/config/StubsConfig.java`
- `file:test/src/main/java/io/f8a/summer/test/config/ServiceConfig.java`
- `file:test/src/main/java/io/f8a/summer/test/config/TestCasesConfig.java`
- `file:test/src/main/java/io/f8a/summer/test/comparison/ComparisonConfig.java`
- `file:test/src/main/java/io/f8a/summer/test/comparison/ComparisonResult.java`
- `file:test/src/main/java/io/f8a/summer/test/runner/BlackboxTestRunner.java`
- `file:test/src/main/java/io/f8a/summer/test/database/PostgresTestContainer.java`
- `file:test/src/test/java/io/f8a/test/wiremock/BlackboxTest.java` (framework's own reference test)
- `file:stubs-guideline.md` (JSON layout convention)
