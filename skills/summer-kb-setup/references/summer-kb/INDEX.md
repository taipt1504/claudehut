# Summer Framework KB — INDEX (hub for consumer-side agents)

**What this is:** lookup surface for agents working in ewallet services (wallet-ms, party-ms, …) that
**consume** Summer (`io.f8a.summer`). Find the topic → jump to the module doc + graph node + source path.

> **Read [USAGE.md](USAGE.md) first** — when you must consult this KB, how to navigate it, and the rule that
> Summer decisions MUST be grounded here, not guessed.

**Doc format:** every module doc follows one canonical template — banner (`Consumer-facing · Auto-config ·
Depends on`) + 7 sections in fixed order: **TL;DR · Activate · Config keys · Public API · Usage · Gotchas ·
Graph refs**. Scan the same slot in any module.

**How to read a pointer:** a **file** graph-node id is `file:<source-path>` (so the path column *is* the node
id). Class/function nodes are written fully as `class:<path>:<Name>` / `function:<path>:<name>`.
Full graph: `.understand-anything/knowledge-graph.json` (1257 nodes, fresh at commit `b6017fb`).

**Activation model:** Summer is a library, not a service. A consumer gets behavior by (1) adding the Gradle
dependency, (2) Spring Boot reading the module's `META-INF/spring/…AutoConfiguration.imports`, (3) the
`@ConditionalOn*` gate passing. Most gates are `matchIfMissing=true` → **on by default once the jar is on the
classpath**; you opt *out*, not in (exceptions noted per module). Group id for every artifact: `io.f8a.summer`.

---

## 1. Module map — pick the doc

| Module doc | Consumer-facing | Auto-config | Depends on | What a consumer gets |
|---|---|---|---|---|
| [core.md](core.md) | yes | none (types only) | — | UFID/Txid value types, `ApiResponse`, exceptions, WebClient factory, masking, outbox/audit contracts |
| [rest.md](rest.md) | yes | default-on | core | Jackson policy, WebFlux Txid/Ufid binding, OpenAPI, global exception→JSON |
| [data.md](data.md) | yes | default-on | core | R2DBC converters, transactional outbox, audit trail, startup schema validators |
| [security.md](security.md) | yes | default-on (apisix) | core, rest | APISIX/JWT resource server, API-key filter, Keycloak admin + role sync |
| [kafka.md](kafka.md) | yes | default-on (idempotency) | core, data | Reactive consumer factory, watermark idempotency, retry/DLT |
| [ratelimit.md](ratelimit.md) | yes | default-on | core | Reactive rate limiting (fixed/sliding window, token bucket) over Redis/in-memory |
| [payment-sdk.md](payment-sdk.md) | yes | manual dep | core | UFID Jackson annotations (`@JE`/`@SE`/`@TX`/`@Compact`/`@UInt128`/`@UfidPrefix`), payment/ledger/wallet/VA event & command contracts |
| [platform.md](platform.md) | yes | BOM | — | java-platform BOM pinning module versions |
| [test.md](test.md) | yes | test-scope | core | WireMock/Testcontainers blackbox test harness |
| [file.md](file.md) | yes | manual dep | — | Streaming CSV/ZIP export utilities |

## 2. Property-prefix + gate cheat-sheet (fast config lookup)

| Prefix | Binds to | Gate (property → default) | Doc |
|---|---|---|---|
| `f8a.common` | `CommonLibProperties` (Jackson/ApiDoc/WebClient/proxy) | `f8a.common.enabled=true` (matchIfMissing) | rest / core |
| `summer.http.logging` | `HttpLoggingProperties` | via rest gates | rest |
| `summer.r2dbc` | `SummerR2dbcProperties` (`txidColumnType`, default `UUID`) | R2DBC on classpath | data |
| `f8a.outbox` | `OutboxProperties` | `f8a.outbox.enabled=true` (matchIfMissing); `f8a.outbox.publisher.mode=cdc` selects CDC | data |
| `f8a.audit` | audit beans | `f8a.audit.validate-on-startup=true` (matchIfMissing) | data |
| `f8a.security.apisix.resource-server` | `ApisixResourceServerProperties` | `…enabled=true` (matchIfMissing) | security |
| `f8a.kafka.consumer` | `KafkaConsumerProperties` (idempotency, retry) | `f8a.kafka.consumer.idempotency.enabled=true` (matchIfMissing); `…idempotency.validate-on-startup=true` | kafka |
| `f8a.rate-limiter` | `RateLimiterProperties` | `f8a.rate-limiter.storage-type=redis` (matchIfMissing) | ratelimit |

## 3. Topic map — "I need X → doc + graph node (= source path)"

### IDs & JSON serialization (payment-sdk + core)
| Need | Doc | Graph node id (= source path) |
|---|---|---|
| UFID value type (128-bit, sortable) | core | `file:core/src/main/java/io/f8a/summer/core/domain/types/ufid/Ufid.java` |
| Txid value type (64-bit Snowflake) | core | `file:core/src/main/java/io/f8a/summer/core/domain/types/txid/Txid.java` |
| Txid generator (machine-id) | core | `file:core/src/main/java/io/f8a/summer/core/domain/types/txid/TxidGenerator.java` |
| Serialize Ufid w/ type prefix | payment-sdk | `file:payment-sdk/src/main/java/io/f8a/summer/payment/annotation/UfidPrefix.java` |
| `@JE`/`@SE`/`@TX` prefix aliases | payment-sdk | `…/payment/annotation/JE.java`, `…/SE.java`, `…/TX.java` |
| `@Compact` (Base32) / `@UInt128` (TigerBeetle) | payment-sdk | `…/payment/annotation/Compact.java`, `…/UInt128.java` |
| Ledger account id (CIF+type+entropy) | payment-sdk | `file:payment-sdk/src/main/java/io/f8a/summer/payment/domain/LedgerAccountId.java` |

### Cross-service Kafka contracts (payment-sdk — sealed interfaces)
| Contract | Doc | Graph node id |
|---|---|---|
| VA events (`va.events`) | payment-sdk | `class:payment-sdk/src/main/java/io/f8a/summer/payment/event/va/VaEvent.java:VaEvent` |
| Wallet events (`wallet.events`) | payment-sdk | `class:payment-sdk/src/main/java/io/f8a/summer/payment/event/wallet/WalletEvent.java:WalletEvent` |
| Wallet commands (`wallet.commands`) | payment-sdk | `class:payment-sdk/src/main/java/io/f8a/summer/payment/event/wallet/WalletCommand.java:WalletCommand` |
| Payment-intent command (`payment.intent.command.v1`) | payment-sdk | `class:payment-sdk/src/main/java/io/f8a/summer/payment/cmd/intent/PaymentIntentCommand.java:PaymentIntentCommand` |

### REST / HTTP (rest + core)
| Need | Doc | Graph node id |
|---|---|---|
| REST umbrella auto-config | rest | `file:rest/rest-autoconfigure/src/main/java/io/f8a/summer/core/autoconfigure/SummerRestAutoConfiguration.java` |
| OpenAPI auto-config | rest | `…/core/autoconfigure/SummerApiDocAutoConfiguration.java` |
| Jackson customization | rest | `…/core/autoconfigure/JacksonAutoConfiguration.java` |
| WebFlux Txid/Ufid formatters + Pageable resolvers | rest | `…/core/autoconfigure/SummerWebfluxConfiguration.java` |
| Global exception → JSON | rest | `file:rest/rest-common/src/main/java/io/f8a/summer/rest/common/exception/SummerGlobalExceptionHandler.java` |
| `ApiResponse<T>` envelope | core | `file:core/src/main/java/io/f8a/summer/core/response/ApiResponse.java` |
| `ViewableException` (throw for mapped HTTP errors) | core | `file:core/src/main/java/io/f8a/summer/core/exception/ViewableException.java` |
| Build outbound WebClient | core | `file:core/src/main/java/io/f8a/summer/core/webclient/WebClientBuilderFactory.java` |
| Mask PII in logs | core | `file:core/src/main/java/io/f8a/summer/core/masking/MaskingUtil.java` |

### Data / Outbox / Audit (data)
| Need | Doc | Graph node id |
|---|---|---|
| Register R2DBC converters (Ufid/Txid/…) | data | `file:data/data-autoconfigure/src/main/java/io/f8a/summer/data/r2dbc/autoconfigure/SummerR2dbcAutoConfiguration.java` |
| `summer.r2dbc.txidColumnType` select | data | `file:data/data-r2dbc/src/main/java/io/f8a/summer/data/r2dbc/config/SummerR2dbcProperties.java` |
| Transactional outbox stack | data | `file:data/data-outbox-autoconfigure/src/main/java/io/f8a/summer/data/audit/autoconfigure/SummerR2dbcOutboxAutoConfiguration.java` |
| Outbox write port | data/core | `file:core/src/main/java/io/f8a/summer/core/outbox/OutboxService.java` |
| Outbox config (`f8a.outbox.*`) | data | `file:data/data-outbox/src/main/java/io/f8a/summer/core/outbox/config/OutboxProperties.java` |
| Audit trail auto-config (`@Audit`) | data | `file:data/data-audit-autoconfigure/src/main/java/io/f8a/summer/data/audit/autoconfigure/SummerR2dbcAuditAutoConfiguration.java` |
| Startup table validator | data | `class:data/data-r2dbc/src/main/java/io/f8a/summer/data/r2dbc/validator/AbstractTableValidator.java:AbstractTableValidator` |

### Security (security)
| Need | Doc | Graph node id |
|---|---|---|
| APISIX resource-server auto-config | security | `file:security/security-autoconfigure/src/main/java/io/f8a/summer/autoconfigure/security/apisix/resource/reactive/ReactiveApisixResourceServerAutoConfiguration.java` |
| Keycloak admin + role sync auto-config | security | `…/reactive/ReactiveApisixKeycloakAdminAutoConfiguration.java` |
| Base reactive resource server | security | `…/base/resource/reactive/ReactiveBaseResourceServerAutoConfiguration.java` |
| APISIX config props | security | `file:security/apisix-resource-server/src/main/java/io/f8a/summer/autoconfigure/security/apisix/resource/ApisixResourceServerProperties.java` |
| Reactive Keycloak admin client | security | `file:security/keycloak/src/main/java/io/f8a/summer/keycloak/ReactiveKeycloakClient.java` |
| Current auth / principal (reactive) | security | `file:security/jwt-resource-server/src/main/java/io/f8a/summer/security/authentication/ReactiveAuthenticationService.java` |

### Messaging — Kafka consumer (kafka)
| Need | Doc | Graph node id |
|---|---|---|
| Consumer auto-config (idempotency, retry/DLT) | kafka | `file:kafka/kafka-consumer-autoconfigure/src/main/java/io/f8a/summer/kafka/consumer/autoconfigure/SummerKafkaConsumerAutoConfiguration.java` |
| Consumer factory (standard listener shape) | kafka | `class:kafka/kafka-consumer/src/main/java/io/f8a/summer/kafka/consumer/factory/SummerKafkaConsumerFactories.java:SummerKafkaConsumerFactories` |
| Watermark idempotency port | kafka | `class:kafka/kafka-consumer/src/main/java/io/f8a/summer/kafka/consumer/idempotency/OutboxConsumerIdempotency.java:OutboxConsumerIdempotency` |
| Consumer props (`f8a.kafka.consumer.*`) | kafka | `class:kafka/kafka-consumer/src/main/java/io/f8a/summer/kafka/consumer/config/KafkaConsumerProperties.java:KafkaConsumerProperties` |

### Rate limiting (ratelimit)
| Need | Doc | Graph node id |
|---|---|---|
| Auto-config (Redis/in-memory store) | ratelimit | `file:ratelimit/ratelimit-autoconfigure/src/main/java/io/f8a/summer/ratelimit/autoconfigure/SummerRateLimitAutoConfiguration.java` |
| Public service (`tryAcquire`/`acquire`) | ratelimit | `file:ratelimit/ratelimit-core/src/main/java/io/f8a/summer/core/ratelimit/RateLimiterService.java` |
| Strategy interface | ratelimit | `class:ratelimit/ratelimit-core/src/main/java/io/f8a/summer/core/ratelimit/RateLimiter.java:RateLimiter` |
| Store abstraction | ratelimit | `class:ratelimit/ratelimit-core/src/main/java/io/f8a/summer/core/ratelimit/store/RateLimitStore.java:RateLimitStore` |
| Props (`f8a.rate-limiter.*`) | ratelimit | `file:ratelimit/ratelimit-core/src/main/java/io/f8a/summer/core/ratelimit/config/RateLimiterProperties.java` |

### Testing & file export
| Need | Doc | Graph node id |
|---|---|---|
| Blackbox WireMock harness | test | `file:test/src/main/java/io/f8a/summer/test/wiremock/WireMockServiceManager.java` |
| Streaming ZIP/CSV export | file | `file:file/src/main/java/io/f8a/summer/file/export/ZipExporter.java` |

## 4. Gradle coordinates (all publishable artifacts, group `io.f8a.summer`)

`summer-core` · `summer-rest-autoconfigure` · `summer-rest-common` · `summer-data-autoconfigure` ·
`summer-data-r2dbc` · `summer-data-outbox` · `summer-data-outbox-autoconfigure` · `summer-data-audit` ·
`summer-data-audit-autoconfigure` · `summer-security-autoconfigure` · `summer-apisix-resource-server` ·
`summer-jwt-resource-server` · `summer-apikey-resource-server` · `summer-keycloak` · `summer-kafka-consumer` ·
`summer-kafka-consumer-autoconfigure` · `summer-ratelimit-core` · `summer-ratelimit-autoconfigure` ·
`summer-payment-sdk` · `summer-platform` (BOM) · `summer-test` · `summer-file`

> Version via the `summer-platform` BOM. Repo: GitLab Maven (`git.newera.inc`, needs `GITLAB_TOKEN`). See repo README.
