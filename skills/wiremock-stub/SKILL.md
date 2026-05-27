---
name: wiremock-stub
description: WireMock stub conventions for HTTP integration tests. Stub mapping JSON format, scenario-based stateful stubs, request matching strategies, fault injection. Auto-loads when editing `src/test/**/*Wiremock*.java` or `**/__stubs/*.json`.
---

# WireMock

Stub external HTTP services for integration tests.

## Quick start

```java
@ExtendWith(WireMockExtension.class)
class PaymentClientTest {

    @RegisterExtension
    static WireMockExtension wireMock = WireMockExtension.newInstance()
        .options(wireMockConfig().dynamicPort())
        .build();

    @Test
    void shouldChargeCard() {
        wireMock.stubFor(post(urlEqualTo("/v1/charges"))
            .withRequestBody(matchingJsonPath("$.amount", equalTo("1000")))
            .willReturn(aResponse()
                .withStatus(200)
                .withHeader("Content-Type", "application/json")
                .withBody("""
                    {"id":"ch_123","status":"succeeded"}
                """)));

        PaymentClient client = new PaymentClient(wireMock.baseUrl());
        ChargeResult result = client.charge(new ChargeRequest(1000, "usd", "tok_x"));

        assertThat(result.id()).isEqualTo("ch_123");
        wireMock.verify(postRequestedFor(urlEqualTo("/v1/charges")));
    }
}
```

## Stub mappings as JSON (declarative)

`src/test/resources/__stubs/payment-success.json`:

```json
{
  "request": {
    "method": "POST",
    "url": "/v1/charges"
  },
  "response": {
    "status": 200,
    "headers": { "Content-Type": "application/json" },
    "jsonBody": { "id": "ch_123", "status": "succeeded" }
  }
}
```

Detailed: `references/stub-mapping-format.md`, `references/scenarios.md`.

## Assets

- `assets/templates/stub-mapping.json.tmpl`
- `assets/templates/WiremockTest.java.tmpl`

## Hard rules

- ALWAYS use dynamic port for parallel test isolation.
- USE JSON stub files for sharable stubs (committed under `src/test/resources/__stubs/`).
- USE scenarios for stateful behavior (e.g., transient → success).
- VERIFY actual call(s) made — `wireMock.verify(...)`.
- CLEAN up between tests with `wireMock.resetAll()` if shared across tests.

## Exit criteria

- [ ] Dynamic port
- [ ] Stub matches narrow enough to detect wrong calls
- [ ] Verification confirms expected calls
- [ ] Scenarios for stateful flows
