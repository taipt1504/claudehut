---
id: rules/testing/wiremock
paths:
  - "**/*Test.java"
severity: medium
tags: [wiremock, http-stub, integration-test]
---


# WireMock Rules

## DO

- Use dynamic port (`wireMockConfig().dynamicPort()`).
- Stub narrowly — match on method, URL, body where possible.
- Verify expected calls happened (`wireMock.verify(...)`).
- Reset stubs between tests (`wireMock.resetAll()`) when shared.
- Use scenarios for stateful flows (retry, session).
- Store reusable stub mappings as JSON in `src/test/resources/__stubs/`.

## DON'T

- Hardcode port — collides on parallel runs.
- Stub `urlPathMatching(".*")` — too broad, masks bugs.
- Skip verification — passes when service makes wrong calls.
- Share state without reset — order-dependent tests.

## Quick reference

```java
@ExtendWith(WireMockExtension.class)
class PaymentClientTest {

    @RegisterExtension
    static WireMockExtension wm = WireMockExtension.newInstance()
        .options(wireMockConfig().dynamicPort())
        .build();

    @Test
    void shouldCharge() {
        wm.stubFor(post("/v1/charges")
            .withRequestBody(matchingJsonPath("$.amount", equalTo("1000")))
            .willReturn(ok()
                .withHeader("Content-Type", "application/json")
                .withBody("""
                    {"id":"ch_123","status":"succeeded"}
                """)));

        ChargeResult result = client.charge(req);

        assertThat(result.id()).isEqualTo("ch_123");
        wm.verify(postRequestedFor(urlEqualTo("/v1/charges")));
    }
}
```

## Matchers

- `urlEqualTo("/path")` — exact.
- `urlPathEqualTo("/path")` — path without query.
- `urlPathMatching("/path/\\d+")` — regex.
- `withQueryParam("name", equalTo("alice"))`.
- `withHeader("Authorization", containing("Bearer "))`.
- `withRequestBody(matchingJsonPath("$.id"))`.
- `withRequestBody(equalToJson("""{"id":"x"}"""))`.

## Response

```java
.willReturn(ok()
    .withHeader("Content-Type", "application/json")
    .withBody("{...}")
    .withFixedDelay(500))    // simulate latency

.willReturn(serverError())   // 500
.willReturn(badRequest())    // 400
.willReturn(aResponse().withFault(Fault.CONNECTION_RESET_BY_PEER))
```

## Scenarios (stateful)

```java
wm.stubFor(get("/x")
    .inScenario("retry")
    .whenScenarioStateIs(STARTED)
    .willReturn(serverError())
    .willSetStateTo("after-failure"));

wm.stubFor(get("/x")
    .inScenario("retry")
    .whenScenarioStateIs("after-failure")
    .willReturn(ok()));
```

## File-based stubs

`src/test/resources/__stubs/payment-success.json`:

```json
{
  "request": {"method": "POST", "url": "/v1/charges"},
  "response": {"status": 200, "jsonBody": {"id": "ch_123"}}
}
```

Loaded automatically when WireMock starts in `--root-dir=./__stubs` mode, or via `wm.loadMappingsFrom(...)`.

## Standalone WireMock for blackbox tests

For full e2e tests outside JUnit:

```bash
java -jar wiremock-standalone.jar --port 8080 --root-dir src/test/resources/__stubs
```

App points to `http://localhost:8080`. Tests run against this.
