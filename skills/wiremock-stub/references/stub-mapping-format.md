# WireMock Stub Mapping Format

## JSON format (declarative)

`src/test/resources/__stubs/payment-success.json`:

```json
{
  "request": {
    "method": "POST",
    "url": "/v1/charges",
    "headers": {
      "Authorization": {
        "contains": "Bearer "
      }
    },
    "bodyPatterns": [
      {
        "matchesJsonPath": "$.amount"
      },
      {
        "equalToJson": "{\"currency\":\"usd\"}",
        "ignoreArrayOrder": true,
        "ignoreExtraElements": true
      }
    ]
  },
  "response": {
    "status": 200,
    "headers": {
      "Content-Type": "application/json"
    },
    "jsonBody": {
      "id": "ch_123",
      "status": "succeeded"
    },
    "fixedDelayMilliseconds": 0
  }
}
```

## Request matchers

| Matcher | Purpose |
|---------|---------|
| `url` / `urlPattern` | URL exact or regex |
| `urlPath` / `urlPathPattern` | path only (ignore query) |
| `method` | HTTP method (`GET`, `POST`, ...) |
| `headers` | header name → value matcher |
| `queryParameters` | query param matchers |
| `bodyPatterns` | body matchers (array, all must match) |
| `cookies` | cookie matchers |
| `basicAuthCredentials` | shorthand for Basic auth |

## Value matchers

| Matcher | Example |
|---------|---------|
| `equalTo` | `{"equalTo": "exact"}` |
| `contains` | `{"contains": "substr"}` |
| `matches` | `{"matches": ".*regex.*"}` |
| `doesNotMatch` | `{"doesNotMatch": "..."}` |
| `equalToJson` | `{"equalToJson": "{\"a\":1}"}` |
| `matchesJsonPath` | `{"matchesJsonPath": "$.field"}` |
| `equalToXml` | `{"equalToXml": "<root>..."}` |
| `matchesXPath` | `{"matchesXPath": "/root/field"}` |
| `absent` | `{"absent": true}` |

## Response options

| Field | Purpose |
|-------|---------|
| `status` | HTTP status code |
| `statusMessage` | HTTP reason phrase |
| `headers` | response headers |
| `body` | body as string |
| `jsonBody` | body as JSON object (auto-serialized) |
| `base64Body` | body as base64 binary |
| `bodyFileName` | external file under `__files/` |
| `fixedDelayMilliseconds` | latency simulation |
| `fault` | inject failures: `CONNECTION_RESET_BY_PEER`, `EMPTY_RESPONSE`, `MALFORMED_RESPONSE_CHUNK`, `RANDOM_DATA_THEN_CLOSE` |

## Scenarios (stateful)

```json
{
  "scenarioName": "retry-flow",
  "requiredScenarioState": "Started",
  "newScenarioState": "after-fail",
  "request": { "method": "GET", "url": "/x" },
  "response": { "status": 503 }
}
```

Each request matches only if scenario in `requiredScenarioState`. State transitions via `newScenarioState`.

## File layout

```
src/test/resources/
├── __stubs/
│   ├── payment-success.json
│   ├── payment-failure.json
│   └── inventory-empty.json
└── __files/
    └── large-response.json    ← referenced by bodyFileName
```

Programmatic load:

```java
wireMock.loadMappingsFrom("src/test/resources/__stubs");
```

Or standalone server mode auto-loads from current dir.

## Anti-patterns

- `urlPattern: ".*"` too broad → masks real bugs
- Stub returning success regardless of body → not verifying request
- Forgetting `Content-Type` header in response → client parsing fails
- Mixing inline + file stubs without convention
- Reset stubs not called between tests → state leak
