# kafka — summer-kafka-consumer, summer-kafka-consumer-autoconfigure
> Consumer-facing: yes · Auto-config: default-on (idempotency) · Depends on: core, data

## TL;DR
- Add `summer-kafka-consumer-autoconfigure` → you get idempotency helper + retry/DLT error handler + JSON listener factories; **no `enabled` flag — presence of the dep is the opt-in**.
- Idempotency is a helper you must **call** from your listener (nothing is intercepted); `recordProcessed` MUST commit in the same tx as the business write.
- Retry exhausts to `<topic>.dlt` via a dedicated `dltKafkaTemplate` (`enable.idempotence=false, acks=1`).

## Activate
| Aspect | Value |
|---|---|
| Gradle | `implementation "io.f8a.summer:summer-kafka-consumer-autoconfigure"` (pulls `summer-kafka-consumer`, `summer-data-r2dbc` transitively) |
| AutoConfiguration | `SummerKafkaConsumerAutoConfiguration` (`@AutoConfiguration(after = KafkaAutoConfiguration.class)`) |
| Idempotency beans gate | `f8a.kafka.consumer.idempotency.enabled` (default true = **on**) + `@ConditionalOnClass R2dbcRepository` |
| Watermark validator gate | `f8a.kafka.consumer.idempotency.validate-on-startup` (default true = **on**) + `@ConditionalOnClass R2dbcRepository` |
| Error-handler / DLT beans | **no property gate** — active whenever spring-kafka + a `KafkaTemplate` bean are present |

Note: there is no module-level `enabled` switch — drop the dependency to remove the module; `idempotency.enabled=false` only disables the two idempotency beans. Every bean is `@ConditionalOnMissingBean`, so declare your own to override any default.

## Config keys
`@ConfigurationProperties("f8a.kafka.consumer")` → `KafkaConsumerProperties`.

| Key | Type | Default | Meaning |
|---|---|---|---|
| `f8a.kafka.consumer.idempotency.enabled` | boolean | `true` | Wire `R2dbcOutboxConsumerIdempotency` (watermark table `outbox_consumer_watermark`) |
| `f8a.kafka.consumer.idempotency.validate-on-startup` | boolean | `true` | `ConsumerWatermarkValidator` fails startup if table missing / columns mismatch |
| `f8a.kafka.consumer.retry.max-attempts` | int | `3` | Retries before routing record to DLT |
| `f8a.kafka.consumer.retry.initial-interval` | Duration | `1s` | Delay before first retry |
| `f8a.kafka.consumer.retry.multiplier` | double | `2.0` | Exponential backoff factor |
| `f8a.kafka.consumer.retry.max-interval` | Duration | `30s` | Cap on any single retry delay |

Broker / SASL / SSL come from standard `spring.kafka.*` (inherited via `KafkaProperties`).

## Public API
| Type | When to use |
|---|---|
| `OutboxConsumerIdempotency` (port: `isProcessed` / `recordProcessed`) | Inject + call from a listener to dedup replays; skip business logic when `isProcessed` is true |
| `IdempotencyContext` (record `consumerGroup, topic, int partition, long lsn, eventId`) | Build from Kafka headers (`ob.lsn`, `ob.eid`) + `KafkaHeaders` to pass to the port |
| `SummerKafkaConsumerFactories` (static `jsonConsumerFactory`, `jsonListenerContainerFactory`) | Declaring a standard JSON `@KafkaListener` container factory per value type |
| `DefaultErrorHandlerCustomizer` (`@FunctionalInterface`) | Add non-retryable exceptions / retry listener to the auto handler **without** replacing it |
| `KafkaConsumerProperties` | Read/override idempotency + retry config keys |
| `dltKafkaTemplate` bean (name `SummerKafkaConsumerAutoConfiguration.DLT_KAFKA_TEMPLATE_BEAN`) | Inject via `@Qualifier("dltKafkaTemplate")` only if you need the DLT producer directly (NOT for transactional producing) |

Not a library: `kafka/kafka-dlt-replayer` is a Python ops CLI for replaying DLT records — not a consumer dependency, not published.

## Usage
```java
// Per-type container factory — reuses the auto summerKafkaDefaultErrorHandler bean
@Bean("ledgerTransferListenerContainerFactory")
ConcurrentKafkaListenerContainerFactory<String, LedgerTransferEvent> factory(
    KafkaProperties props, DefaultErrorHandler errorHandler) {
  var cf = SummerKafkaConsumerFactories.jsonConsumerFactory(props, LedgerTransferEvent.class);
  return SummerKafkaConsumerFactories.jsonListenerContainerFactory(props, cf, errorHandler);
}

// Listener — dedup + business write MUST commit in ONE transaction
@KafkaListener(topics = "ledger.transfer.posted", containerFactory = "ledgerTransferListenerContainerFactory")
Mono<Void> onPosted(@Payload LedgerTransferEvent event,
    @Header(KafkaHeaders.GROUP_ID) String group, @Header(KafkaHeaders.RECEIVED_TOPIC) String topic,
    @Header(KafkaHeaders.RECEIVED_PARTITION) int partition, @Header("ob.lsn") long lsn,
    @Header(name = "ob.eid", required = false) String eventId, Acknowledgment ack) {
  var ctx = new IdempotencyContext(group, topic, partition, lsn, eventId);
  return idempotency.isProcessed(ctx)
      .flatMap(seen -> seen ? Mono.empty() : txOperator.transactional(handle(event).then(idempotency.recordProcessed(ctx))))
      .doFinally(s -> ack.acknowledge());  // ack mode is MANUAL_IMMEDIATE
}
```

## Gotchas
- `recordProcessed` MUST commit in the SAME tx as the business write (`TransactionalOperator` / `@Transactional`); a crash between two separate commits reopens a duplicate-processing window.
- Watermark upsert only advances (`ON CONFLICT ... WHERE outbox_consumer_watermark.last_lsn < EXCLUDED.last_lsn`); lower/equal LSN is a no-op. `isProcessed` returns true when `ctx.lsn() <= watermark`.
- Key by `(consumerGroup, topic, partition)` — never by source DB; multiple topics from one source have interleaving LSNs, source-keying causes false skips.
- LSN ordering is authoritative only in Debezium CDC mode; scheduler-mode publishers emit `createdAt.toEpochNanos()` — best-effort, not strict under extreme concurrency.
- Idempotency beans need Spring Data R2DBC on the classpath (`@ConditionalOnClass R2dbcRepository`, satisfied via `summer-data-r2dbc`); if absent, the beans silently don't register.
- Nothing is intercepted automatically — the autoconfig only wires the helper; the listener must actually call `isProcessed`/`recordProcessed`.
- DLT topic is `<topic> + ".dlt"` (lowercase, set in the autoconfig's `DeadLetterPublishingRecoverer`), NOT `.DLT` as the `Retry` javadoc prose says.
- Auto `DefaultErrorHandler` marks these NON-retryable (straight to DLT): `DeserializationException`, `MessageConversionException`, `ConversionException`, `IllegalArgumentException`. Add more via a `DefaultErrorHandlerCustomizer` bean; replace wholesale by declaring your own `DefaultErrorHandler` (autoconfig backs off, customizers then NOT invoked).
- `dltKafkaTemplate` is `defaultCandidate=false` → invisible to type-based autowiring (inject via `@Qualifier("dltKafkaTemplate")`). It runs `enable.idempotence=false, acks=1` and skips `transactionIdPrefix` — do NOT reuse it for transactional producing.
- `jsonConsumerFactory` sets `JsonDeserializer.TRUSTED_PACKAGES="*"` (via `putIfAbsent`) and `USE_TYPE_INFO_HEADERS=false`, value type fixed to the passed `Class`; wraps both key+value in `ErrorHandlingDeserializer`. Override `TRUSTED_PACKAGES` if your threat model forbids arbitrary classes. Non-JSON/Avro or non-String-key consumers must build their own `ConsumerFactory`.
- Container defaults from the factory: ack mode `MANUAL_IMMEDIATE` (you must `ack.acknowledge()`), concurrency `1` (mutate the returned factory before it becomes a bean), observation inherited from `spring.kafka.listener.observation-enabled`.
- `recordProcessed` substitutes UUID `00000000-0000-0000-0000-000000000000` when `ctx.eventId()` is null (`last_event_id` is audit-only).
- `ConsumerWatermarkValidator` extends `summer-data-r2dbc` `AbstractTableValidator`; it checks column types (`last_lsn` BIGINT, `last_event_id` UUID, `last_updated_at` TIMESTAMPTZ, etc.) and emits a migration-script hint on mismatch. Create the table via Flyway/Liquibase.

## Graph refs
- `file:kafka/kafka-consumer-autoconfigure/src/main/java/io/f8a/summer/kafka/consumer/autoconfigure/SummerKafkaConsumerAutoConfiguration.java`
- `class:kafka/kafka-consumer-autoconfigure/src/main/java/io/f8a/summer/kafka/consumer/autoconfigure/SummerKafkaConsumerAutoConfiguration.java:SummerKafkaConsumerAutoConfiguration`
- `file:kafka/kafka-consumer/src/main/java/io/f8a/summer/kafka/consumer/config/KafkaConsumerProperties.java`
- `class:kafka/kafka-consumer/src/main/java/io/f8a/summer/kafka/consumer/config/KafkaConsumerProperties.java:KafkaConsumerProperties`
- `file:kafka/kafka-consumer/src/main/java/io/f8a/summer/kafka/consumer/factory/SummerKafkaConsumerFactories.java`
- `class:kafka/kafka-consumer/src/main/java/io/f8a/summer/kafka/consumer/factory/SummerKafkaConsumerFactories.java:SummerKafkaConsumerFactories`
- `file:kafka/kafka-consumer/src/main/java/io/f8a/summer/kafka/consumer/idempotency/OutboxConsumerIdempotency.java`
- `class:kafka/kafka-consumer/src/main/java/io/f8a/summer/kafka/consumer/idempotency/OutboxConsumerIdempotency.java:OutboxConsumerIdempotency`
- `file:kafka/kafka-consumer/src/main/java/io/f8a/summer/kafka/consumer/idempotency/R2dbcOutboxConsumerIdempotency.java`
- `class:kafka/kafka-consumer/src/main/java/io/f8a/summer/kafka/consumer/idempotency/R2dbcOutboxConsumerIdempotency.java:R2dbcOutboxConsumerIdempotency`
- `file:kafka/kafka-consumer/src/main/java/io/f8a/summer/kafka/consumer/idempotency/IdempotencyContext.java`
- `class:kafka/kafka-consumer/src/main/java/io/f8a/summer/kafka/consumer/idempotency/IdempotencyContext.java:IdempotencyContext`
- `file:kafka/kafka-consumer/src/main/java/io/f8a/summer/kafka/consumer/idempotency/ConsumerWatermarkValidator.java`
- `class:kafka/kafka-consumer/src/main/java/io/f8a/summer/kafka/consumer/idempotency/ConsumerWatermarkValidator.java:ConsumerWatermarkValidator`
- `file:kafka/kafka-consumer/src/main/java/io/f8a/summer/kafka/consumer/errorhandler/DefaultErrorHandlerCustomizer.java`
- `class:kafka/kafka-consumer/src/main/java/io/f8a/summer/kafka/consumer/errorhandler/DefaultErrorHandlerCustomizer.java:DefaultErrorHandlerCustomizer`
- `file:kafka/kafka-consumer-autoconfigure/src/main/resources/META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports`
