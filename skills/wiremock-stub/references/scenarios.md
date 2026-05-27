# WireMock Scenarios — Stateful Stubs

## Why scenarios

Tests sometimes need a sequence of responses for the same URL:
- First call: 503 (transient failure).
- Second call: 200 (recovered).

Scenarios encode this state machine.

## Example — retry on transient failure

```java
@Test
void shouldRetry_when5xx_thenSucceed() {
    String scenario = "retry-flow";

    wireMock.stubFor(get(urlEqualTo("/api/x"))
        .inScenario(scenario)
        .whenScenarioStateIs(Scenario.STARTED)
        .willReturn(serverError())
        .willSetStateTo("after-first-failure"));

    wireMock.stubFor(get(urlEqualTo("/api/x"))
        .inScenario(scenario)
        .whenScenarioStateIs("after-first-failure")
        .willReturn(ok().withBody("success")));

    String result = client.fetchWithRetry();

    assertThat(result).isEqualTo("success");
    wireMock.verify(2, getRequestedFor(urlEqualTo("/api/x")));
}
```

## JSON scenario stub

```json
[
  {
    "scenarioName": "retry-flow",
    "requiredScenarioState": "Started",
    "newScenarioState": "after-first-failure",
    "request": { "method": "GET", "url": "/api/x" },
    "response": { "status": 503 }
  },
  {
    "scenarioName": "retry-flow",
    "requiredScenarioState": "after-first-failure",
    "request": { "method": "GET", "url": "/api/x" },
    "response": { "status": 200, "body": "success" }
  }
]
```

## Reset scenarios between tests

```java
@AfterEach
void resetScenarios() {
    wireMock.resetScenarios();  // back to Started
}
```

## Other use cases

- Rate limit simulation: first 10 calls succeed, 11th → 429.
- Session lifecycle: login → call → logout.
- Token refresh: 401 → token refresh → retry succeeds.

## Anti-patterns

- Many scenarios in one test — split tests.
- State name typos (silent — wrong stub matches).
- Forgetting reset → tests order-dependent.
