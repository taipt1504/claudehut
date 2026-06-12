---
id: rules/testing/wiremock
paths:
  - "**/*Test.java"
  - "**/*IT.java"
  - "**/*IntegrationTest*.java"
severity: medium
tags: [wiremock, http-stub, integration-test]
---
<!-- ClaudeHut rule template — generated into .claude/rules/testing/wiremock.md by claudehut-init. Reused & enhanced from committed rules/testing/wiremock.md. -->


# WireMock Rules

## Server setup — declarative vs programmatic

| Need | Approach |
|---|---|
| Single server, simplest | `@WireMockTest` — injects `WireMockRuntimeInfo`; dynamic port by default |
| Multiple servers / extensions | `@RegisterExtension static WireMockExtension` + `resetAll()` in `@BeforeEach` |
| Per-test hermetic isolation | `@RegisterExtension` **instance** field (non-static) — new server each test, slower |
| Fixed port (legacy) | `@WireMockTest(httpPort = 8080)` — avoid: collides on parallel CI |

**Static extension = shared server → MUST `resetAll()` in `@BeforeEach`.**
Skipping causes stub + request-journal accumulation → order-dependent flaky failures (pass alone, fail in suite).

## Declarative (preferred)

```java
@WireMockTest
class PaymentClientTest {
    @Test
    void shouldCharge(WireMockRuntimeInfo wmRuntimeInfo) {
        // configure client with "http://localhost:" + wmRuntimeInfo.getHttpPort()
        stubFor(post("/v1/charges")
            .withRequestBody(matchingJsonPath("$.amount", equalTo("1000")))
            .willReturn(ok().withHeader("Content-Type","application/json")
                .withBody("""{"id":"ch_123","status":"succeeded"}""")));

        assertThat(client.charge(req).id()).isEqualTo("ch_123");

        // Verify the request actually fired — stub that never matches passes silently
        verify(postRequestedFor(urlEqualTo("/v1/charges"))
            .withHeader("Authorization", containing("Bearer ")));
    }
}
```

## Programmatic (static, shared)

```java
@RegisterExtension
static WireMockExtension wm = WireMockExtension.newInstance()
    .options(wireMockConfig().dynamicPort())
    .build();

@BeforeEach void reset() { wm.resetAll(); }  // clears stubs + journal
```

## DO / DON'T

| DO | DON'T |
|---|---|
| Dynamic port via `wmRuntimeInfo.getHttpPort()` or `wm.port()` | Hardcode port |
| `verify()` the request (method + path + headers + body) | Skip verify — wrong calls pass silently |
| `resetAll()` in `@BeforeEach` for static extension | Share state without reset |
| Scenarios for retry/sequence flows | `urlPathMatching(".*")` catch-alls |

## Matchers

- `urlEqualTo("/path")` — exact. `urlPathEqualTo("/path")` — ignores query.
- `urlPathMatching("/path/\\d+")` — regex path.
- `withQueryParam("name", equalTo("alice"))`.
- `withHeader("Authorization", containing("Bearer "))`.
- `withRequestBody(matchingJsonPath("$.id"))`.
- `withRequestBody(equalToJson("""{"id":"x"}""", IGNORE_ARRAY_ORDER, IGNORE_EXTRA_ELEMENTS))`.

## Response builders

```java
.willReturn(ok().withHeader("Content-Type","application/json").withFixedDelay(500))
.willReturn(serverError())   // 500
.willReturn(aResponse().withFault(Fault.CONNECTION_RESET_BY_PEER))   // hard network fault
.willReturn(aResponse().withFault(Fault.EMPTY_RESPONSE))             // socket closed
```

## Fault injection — pair with timeout/retry assertion

```java
wm.stubFor(post("/v1/charges").inScenario("retry")
    .whenScenarioStateIs(STARTED)
    .willReturn(aResponse().withFault(Fault.CONNECTION_RESET_BY_PEER))
    .willSetStateTo("second-attempt"));
wm.stubFor(post("/v1/charges").inScenario("retry")
    .whenScenarioStateIs("second-attempt")
    .willReturn(ok().withBody("""{"id":"ch_123"}""")));

client.charge(req);
wm.verify(2, postRequestedFor(urlEqualTo("/v1/charges")));  // proves retry fired
```

## Scenarios — state machines

```java
wm.stubFor(get("/x").inScenario("s").whenScenarioStateIs(STARTED)
    .willReturn(serverError()).willSetStateTo("fail-seen"));
wm.stubFor(get("/x").inScenario("s").whenScenarioStateIs("fail-seen")
    .willReturn(ok()));
```

Use for: retry logic, pagination, one-time tokens, session state.

## Proxy / record mode (bootstrap stubs from real service)

```java
wm.startRecording(recordSpec().forTarget("https://api.stripe.com")
    .captureHeader("Authorization"));
// ... run client calls ...
wm.stopRecording();  // saves JSON mappings to __stubs/
```

Commit the saved mappings; remove record config before CI. Never leave proxy mode active — hits real services.

## File-based stubs

```json
// src/test/resources/__stubs/payment-success.json
{"request":{"method":"POST","url":"/v1/charges"},
 "response":{"status":200,"jsonBody":{"id":"ch_123"}}}
```

Load via `wm.loadMappingsFrom("src/test/resources/__stubs")` or standalone `--root-dir`.

## Standalone

```bash
java -jar wiremock-standalone.jar --port 8080 --root-dir src/test/resources/__stubs
```

## Anti-patterns

| Anti-pattern | Failure mode |
|---|---|
| Static extension, no `resetAll()` | Stub leak → test A's stub matches test B's call; order-dependent failures |
| No `verify()` | Client calls wrong URL or never calls — test green anyway |
| `Fault.*` without timeout assertion | Resilience path not actually proven if client silently swallows error |
| Record mode left on in CI | Hits production API; network-sensitive and cost-incurring |
