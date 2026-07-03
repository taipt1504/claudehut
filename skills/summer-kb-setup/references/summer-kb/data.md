# data — summer-data-r2dbc, summer-data-autoconfigure, summer-data-outbox, summer-data-outbox-autoconfigure, summer-data-audit, summer-data-audit-autoconfigure
> Consumer-facing: yes · Auto-config: default-on · Depends on: core

## TL;DR
- Three independent autoconfig artifacts: R2DBC converters, outbox, audit — mix and match by dependency.
- Converters activate on classpath (no property); outbox + audit are on-by-default via `matchIfMissing=true` gates.
- Inject `OutboxService.saveEvent(...)` inside your reactive tx; annotate reactive methods with `@Audit`.

## Activate
| Capability | AutoConfiguration | Gate (prefix.name → default) | Coordinate |
|---|---|---|---|
| R2DBC converters | `SummerR2dbcAutoConfiguration` | `@ConditionalOnClass(R2dbcCustomConversions)` — no property; on whenever Spring Data R2DBC is on cp | `summer-data-autoconfigure` (pulls `summer-data-r2dbc`) |
| Outbox | `SummerR2dbcOutboxAutoConfiguration` | `f8a.outbox.enabled` → **on by default**; also `@ConditionalOnClass(R2dbcRepository)` | `summer-data-outbox-autoconfigure` (pulls `summer-data-outbox`) |
| Audit | `SummerR2dbcAuditAutoConfiguration` | `@ConditionalOnClass(R2dbcRepository)` — no property; `AuditService`+`AuditAspect` always wired | `summer-data-audit-autoconfigure` (pulls `summer-data-audit`) |

Note: publish path chosen by `f8a.outbox.publisher.mode` (default `scheduler`); CDC beans wire on `mode=cdc` alone (property gate only — no Debezium classpath guard, so a `mode=cdc` app missing the Debezium libs fails at startup).

## Config keys
| Key | Default | Notes |
|---|---|---|
| `summer.r2dbc.txid-column-type` | `uuid` | `uuid`\|`bigint` — selects the single Txid *writing* converter |
| `f8a.outbox.enabled` | `true` | master gate for the whole outbox autoconfig |
| `f8a.outbox.validate-on-startup` | `true` | `OutboxTableValidator` fail-fast on `outbox_events` schema |
| `f8a.outbox.publisher.mode` | `scheduler` | `scheduler` (poll) \| `cdc` (Debezium WAL) |
| `f8a.outbox.publisher.queue` | `kafka` | `kafka` → auto-wires `KafkaOutboxPublisher` |
| `f8a.outbox.publisher.topic-prefix` | `""` | prepended to `eventType` → topic; empty ⇒ topic == eventType |
| `f8a.outbox.publisher.scheduler.cron` | `*/5 * * * * *` | poll cron (scheduler mode only) |
| `f8a.outbox.publisher.scheduler.batch-size` | `100` | events per poll |
| `f8a.outbox.publisher.cdc.*` | — | CDC-only: `url`/`username`/`password` (JDBC + REPLICATION), `slot-name=outbox_cdc_slot`, `table-include-list=.*\.outbox_events`, `plugin-name=pgoutput`, `publish-timeout=30s`, `skip-already-published=true`, `offset-storage-topic=debezium.outbox.offsets` |
| `f8a.outbox.retry.max-attempts` | `5` | at/above → surfaced by monitoring, not retried |
| `f8a.outbox.retry.initial-interval` / `.multiplier` / `.max-interval` | `1s` / `2.0` / `60s` | `delay(n)=min(initial*mult^(n-1), max)` |
| `f8a.outbox.retry.poll-interval` / `.batch-size` | `10s` / `100` | retry task loop |
| `f8a.outbox.cleanup.cron` / `.retention` | `0 0 2 * * ?` / `30d` | old-row pruning (both modes) |
| `f8a.outbox.monitoring.cron` | `0 0 * * * ?` | logs stuck events |
| `f8a.outbox.circuit-breaker.enabled` | `true` | gates `OutboxCircuitBreakerRegistry` bean |
| `f8a.outbox.circuit-breaker.failure-rate-threshold` / `.minimum-events` / `.wait-duration` / `.sliding-window-size` | `50` / `10` / `60s` / `100` | per-event-type breaker |
| `f8a.audit.validate-on-startup` | `true` | gate-only (no `@ConfigurationProperties`); `AuditTableValidator` fail-fast on `audit_log` |

Bound `@ConfigurationProperties`: `SummerR2dbcProperties` (`summer.r2dbc`), `OutboxProperties` (`f8a.outbox`). No `f8a.audit` properties class — `validate-on-startup` is read only via `@ConditionalOnProperty`.

## Public API
| Type | Kind | When to use |
|---|---|---|
| `OutboxService` | interface (impl `OutboxServiceImpl`) | inject + `saveEvent(...)` inside a business tx to publish an Event |
| `OutboxEvent` | `@Table("outbox_events")` entity | the row `saveEvent` persists; returned `Mono` |
| `OutboxEventPublisher` | port (default `KafkaOutboxPublisher`) | declare your own `@Bean` to change transport / topic strategy |
| `OutboxHeaders` | constants (`LSN`, `EVENT_ID`) | read transport headers on the consuming side |
| `OutboxProperties` | `@ConfigurationProperties("f8a.outbox")` | reference for every outbox key above |
| `@Audit` | method annotation (`action`, `intent`, `comment`) | audit a reactive service method on `Mono`/`Flux` completion |
| `AuditService` | interface (impl `AuditServiceIml`) | inject when you need programmatic (non-annotation) audit writes |
| `AuditLog` | entity (`@Table("audit_log")`) | payload written by the aspect/service |
| `SummerR2dbcProperties` / `TxidColumnType` | `@ConfigurationProperties("summer.r2dbc")` + enum | flip Txid column type to `bigint` |
| converters (`Ufid`/`Txid`/`TxidUuid`/`JsonNode`/`Password`/`PhoneNumber`) | auto-registered | not called directly; register own bean only to override |

## Usage
```java
// Outbox — save in the SAME reactive tx as the business write:
outboxService.saveEvent(aggregateId, "wallet.credited", payloadJsonNode);          // topic = topicPrefix + eventType
outboxService.saveEvent(aggregateId, "va.reserved", payloadJsonNode, "va.events"); // explicit topic

// Audit — aspect fires on Mono/Flux completion:
@Audit(action = "TRANSFER", intent = "USER_REQUEST", comment = "p2p transfer")
public Mono<Void> transfer(...) { ... }
```
```yaml
f8a:
  outbox:
    publisher: { mode: scheduler, topic-prefix: "wallet." }   # cdc also needs Debezium on cp + wal_level=logical
summer:
  r2dbc: { txid-column-type: uuid }                            # uuid (default) | bigint
```
Custom transport: declare your own `OutboxEventPublisher` `@Bean` — `KafkaOutboxPublisher` backs off (`@ConditionalOnMissingBean`).

## Gotchas
- Txid **writer** is single-selected by `summer.r2dbc.txid-column-type` (uuid→`TxidUuidConverter.Writing`, bigint→`TxidConverter.Writing`); both **readers** are always registered (unambiguous by driver source type). Registering both writers would let Spring resolve by Java type alone and silently bind the wrong SQL type — writes must target one column kind.
- `AbstractTableValidator` is an `ApplicationRunner`: on table/column mismatch it logs the migration script and throws `IllegalStateException`, aborting startup. Disable per table with `f8a.outbox.validate-on-startup=false` / `f8a.audit.validate-on-startup=false`.
- CDC mode: Debezium libs are `compileOnly` in `summer-data-outbox` — a `mode=cdc` consumer must add them. The `CdcConfiguration` is gated only by `mode=cdc` (no `@ConditionalOnClass` on Debezium), so missing libs fail at startup with `NoClassDefFoundError` — there is no silent back-off. Requires Postgres `wal_level=logical`.
- CDC mode reuses the main `spring.kafka.*` client for offset/schema-history storage; the `debeziumCdcEngine` bean throws `IllegalStateException` at startup if `spring.kafka.bootstrap-servers` is empty. No separate config path.
- `KafkaOutboxPublisher` wires only when spring-kafka on cp + a `KafkaTemplate` bean exists + no other `OutboxEventPublisher` present + `f8a.outbox.publisher.queue=kafka`.
- Retry, cleanup, monitoring, circuit-breaker run in **both** modes; only the `publisher.scheduler.*` or `publisher.cdc.*` block matching `mode` is consulted. `@EnableScheduling` is turned on by the outbox autoconfig.
- Key autoconfig beans are `@ConditionalOnMissingBean` — override `OutboxService`, `AuditService`, `AuditAspect`, validators, publisher by declaring your own (the scheduler dispatcher, CDC beans, and the R2DBC converters bean are not guarded this way).
- `@Audit` only fires on `Mono`/`Flux` returns; on any other return type the aspect skips (no audit written).
- 4-arg `saveEvent(..., topic)` decouples routing from `eventType` (topic-per-aggregate, cross-service inboxes); `null` topic ⇒ `topicPrefix + eventType`.

## Graph refs
- `class:data/data-autoconfigure/src/main/java/io/f8a/summer/data/r2dbc/autoconfigure/SummerR2dbcAutoConfiguration.java:SummerR2dbcAutoConfiguration`
- `class:data/data-outbox-autoconfigure/src/main/java/io/f8a/summer/data/audit/autoconfigure/SummerR2dbcOutboxAutoConfiguration.java:SummerR2dbcOutboxAutoConfiguration`
- `class:data/data-audit-autoconfigure/src/main/java/io/f8a/summer/data/audit/autoconfigure/SummerR2dbcAuditAutoConfiguration.java:SummerR2dbcAuditAutoConfiguration`
- `class:data/data-r2dbc/src/main/java/io/f8a/summer/data/r2dbc/config/SummerR2dbcProperties.java:SummerR2dbcProperties`
- `class:data/data-r2dbc/src/main/java/io/f8a/summer/data/r2dbc/config/TxidColumnType.java:TxidColumnType`
- `class:data/data-r2dbc/src/main/java/io/f8a/summer/data/r2dbc/validator/AbstractTableValidator.java:AbstractTableValidator`
- `file:data/data-r2dbc/src/main/java/io/f8a/summer/data/r2dbc/converter/`
- `class:core/src/main/java/io/f8a/summer/core/outbox/OutboxService.java:OutboxService`
- `class:data/data-outbox/src/main/java/io/f8a/summer/core/outbox/service/OutboxServiceImpl.java:OutboxServiceImpl`
- `class:core/src/main/java/io/f8a/summer/core/outbox/model/OutboxEvent.java:OutboxEvent`
- `class:data/data-outbox/src/main/java/io/f8a/summer/core/outbox/config/OutboxProperties.java:OutboxProperties`
- `class:data/data-outbox/src/main/java/io/f8a/summer/core/outbox/publisher/OutboxEventPublisher.java:OutboxEventPublisher`
- `class:data/data-outbox/src/main/java/io/f8a/summer/core/outbox/publisher/KafkaOutboxPublisher.java:KafkaOutboxPublisher`
- `class:data/data-outbox/src/main/java/io/f8a/summer/core/outbox/validator/OutboxTableValidator.java:OutboxTableValidator`
- `class:data/data-outbox/src/main/java/io/f8a/summer/core/outbox/cdc/DebeziumCdcEngine.java:DebeziumCdcEngine`
- `class:data/data-outbox/src/main/java/io/f8a/summer/core/outbox/scheduler/OutboxCircuitBreakerRegistry.java:OutboxCircuitBreakerRegistry`
- `class:core/src/main/java/io/f8a/summer/core/audit/Audit.java:Audit`
- `class:core/src/main/java/io/f8a/summer/core/audit/AuditService.java:AuditService`
- `class:data/data-audit/src/main/java/io/f8a/summer/core/audit/aspect/AuditAspect.java:AuditAspect`
- `class:data/data-audit/src/main/java/io/f8a/summer/core/audit/validator/AuditTableValidator.java:AuditTableValidator`
