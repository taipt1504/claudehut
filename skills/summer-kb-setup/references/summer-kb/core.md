# core — summer-core
> Consumer-facing: yes · Auto-config: none (types only, no beans) · Depends on: none (leaf)

## TL;DR
- Ships **zero beans / zero auto-config** (no `src/main/resources`, no `AutoConfiguration.imports`) — import and call types directly; usually arrives transitively via other Summer modules.
- Holds the two `@ConfigurationProperties` classes (`f8a.common`, `summer.http.logging`) but **does not bind them** — `summer-rest` does; the keys only take effect with `summer-rest` on the classpath.
- `TxidGenerator` is the one stateful thing: one-per-JVM, needs a unique machine-id (0..63) or it **throws** at construction.

## Activate
| Aspect | Value |
|---|---|
| Gradle | `implementation "io.f8a.summer:summer-core"` (version via `summer-platform` BOM) |
| AutoConfiguration class | none |
| Gate property | none — no `@ConditionalOn*`, nothing to opt into |
| Beans | none — all entry points are value types / `static` utils / interfaces |

Note: `f8a.common.*` / `summer.http.logging.*` are only honored when `summer-rest-autoconfigure` is present (that module binds + consumes them); on `summer-core` alone they are inert.

## Config keys
Bound by `summer-rest`, not this module (declared here). Keys that matter:

| Key | Default | Effect |
|---|---|---|
| `f8a.common.enabled` | `true` (matchIfMissing) | master switch for rest's `EnableAllAutoConfig` block |
| `f8a.common.web-client.connect-timeout` | `10s` | `WebClientBuilderFactory` connect timeout |
| `f8a.common.web-client.read-timeout` | `30s` | response read timeout |
| `f8a.common.web-client.max-connections` | `100` | reactor-netty pool size (`connection-pool-name` = `summer-webclient-pool`) |
| `f8a.common.web-client.logging-enabled` | `true` | attach `LoggingInterceptor` filter |
| `f8a.common.web-client.error-handling-enabled` | `true` | attach `ErrorHandler` (body→`DownstreamException`) |
| `f8a.common.web-client.proxy.enabled` | `true` | proxy handling on; with `use-system-properties=true` (default) it's a **no-op unless JVM proxy sys-props are set** |
| `f8a.common.web-client.proxy.use-system-properties` | `true` | `false` → use explicit `proxy.host`/`proxy.port`/`proxy.type`/`proxy.non-proxy-hosts` |
| `f8a.common.jackson.enabled` | `true` | rest's Jackson customizer; individual `jackson.*` sub-flags are hardcoded by rest and mostly inert (see rest.md) |
| `summer.http.logging.enabled` | `false` | rest's `RequestLoggingWebFilter` (reactive only) |
| `summer.http.logging.log-headers` | `false` | log masked request headers at DEBUG |

## Public API
| Type | When to use | Node |
|---|---|---|
| `Ufid` | need a 128-bit time-sortable id; `generate()`, store `toUUID()`, parse `fromString(s)` | `class:core/src/main/java/io/f8a/summer/core/domain/types/ufid/Ufid.java:Ufid` |
| `Txid` | need a 59-bit Snowflake ref; `of(long)`, `toLong()` → BIGINT, `toString()` → 18-digit | `class:core/src/main/java/io/f8a/summer/core/domain/types/txid/Txid.java:Txid` |
| `TxidGenerator` | mint `Txid`s; register once per JVM with a machine-id | `class:core/src/main/java/io/f8a/summer/core/domain/types/txid/TxidGenerator.java:TxidGenerator` |
| `MachineIdResolver` | supply the machine-id arg from env/hostname | `class:core/src/main/java/io/f8a/summer/core/domain/types/txid/MachineIdResolver.java:MachineIdResolver` |
| `Password`, `PhoneNumber` | typed value objects (+ `@ValidPassword`/`@ValidPhoneNumber`) | `class:core/src/main/java/io/f8a/summer/core/domain/types/password/Password.java:Password` |
| `ApiResponse<T>` | wrap a controller return; `success(data)` / `fromViewableException(ex)` | `class:core/src/main/java/io/f8a/summer/core/response/ApiResponse.java:ApiResponse` |
| `ViewableException` | throw a mapped HTTP error (status+code+field detail); fluent `detailIssue/detailValue` | `class:core/src/main/java/io/f8a/summer/core/exception/ViewableException.java:ViewableException` |
| `CommonExceptions` / `DownstreamException` | reuse prebuilt errors / signal a downstream-call failure | `file:core/src/main/java/io/f8a/summer/core/exception/CommonExceptions.java` |
| `WebClientBuilderFactory` | build an outbound reactive `WebClient` (`newClient(options)`); inject it from summer-rest | `class:core/src/main/java/io/f8a/summer/core/webclient/WebClientBuilderFactory.java:WebClientBuilderFactory` |
| `MaskingUtil` | mask PII for logs/output: `maskPhone/maskIdNumber/maskBankAccount/maskCardNumber` | `class:core/src/main/java/io/f8a/summer/core/masking/MaskingUtil.java:MaskingUtil` |
| `HeaderConstants` | reference header names (`X_USER_INFO`, `CONTENT_TYPE`, …) | `file:core/src/main/java/io/f8a/summer/core/constants/HeaderConstants.java` |
| `Member` / `CallerAware` | read caller identity (id/username/authorities/adminType) | `class:core/src/main/java/io/f8a/summer/core/security/authentication/Member.java:Member` |
| `OutboxService` | write an outbox event: `saveEvent(aggregateId, eventType, payload[, topic])` — impl in `summer-data-outbox` | `class:core/src/main/java/io/f8a/summer/core/outbox/OutboxService.java:OutboxService` |
| `@Audit` (+ `AuditAction`/`AuditField`) | annotate a method for the audit trail — aspect in `summer-data-audit` | `class:core/src/main/java/io/f8a/summer/core/audit/Audit.java:Audit` |
| `ObjectMapperUtil` | **@Deprecated** — do NOT use; prefer the Spring-managed `ObjectMapper` | `file:core/src/main/java/io/f8a/summer/core/util/ObjectMapperUtil.java` |

## Usage
```java
// Ufid: pure static, DB-storable as UUID
Ufid id = Ufid.generate();                 // store id.toUUID(); parse Ufid.fromString(s)

// Txid: one generator per JVM, machine-id from env / StatefulSet ordinal
@Bean
TxidGenerator txidGenerator() {
  return new TxidGenerator(MachineIdResolver.resolve());
}
Txid ref = txidGenerator.next();           // ref.toLong() → BIGINT; ref.toString() → 18-digit

// REST envelope + domain error
return ApiResponse.success(dto);           // {code:"SUCCESS", success:true, data:…}
throw new ViewableException("WALLET_NOT_FOUND", HttpStatus.NOT_FOUND)
        .detailIssue("walletId", "not found");

// Outbound WebClient (factory injected from summer-rest)
WebClient client = webClientBuilderFactory.newClient(
    WebClientBuilderOptions.builder().baseUrl("https://party-ms").build());
```

## Gotchas
- **No beans here.** `WebClientBuilderFactory` is instantiated by `summer-rest` (needs `CommonLibProperties.WebClient` + `LoggingInterceptor` + `ErrorHandler`); construct it yourself only if you pass all three ctor args.
- **`TxidGenerator` needs a unique machine-id (0..63) or throws.** `MachineIdResolver.resolve()` reads env `SUMMER_TXID_MACHINE_ID` / sys-prop `summer.txid.machine-id`, then the trailing ordinal of `HOSTNAME` (`<svc>-<n>`), else throws — never hash-falls-back. Two pods sharing an id emit colliding `Txid`s. (Javadoc still shows the old `F8A_TXID_MACHINE_ID` name; real constant is `SUMMER_TXID_MACHINE_ID`.)
- **`TxidGenerator` ceiling is 4096 ids/ms/machine** (busy-waits past it); clock going backwards >100 ms throws `IllegalStateException`.
- **`Txid` epoch is 2026-01-01Z** (`EPOCH_MS = 1_767_225_600_000L`) — do not decode its timestamp against the Unix epoch.
- **`Txid.fromUUID/from16Bytes/fromUInt128` are strict** — non-zero high bits / negative low half throw rather than truncate; they only round-trip values from the matching `to*`.
- **`Ufid` Jackson/DB form is the UUID string** (`@JsonValue` = `toUUID().toString()` = `toString()`); `fromString` auto-detects UUID / 26-char Base32 / display forms.
- **`ObjectMapperUtil` is `@Deprecated`** and returns a bare `new ObjectMapper()` (no JavaTimeModule/NON_NULL) — use the summer-rest-managed `ObjectMapper`.
- **`OutboxService` / `@Audit` are contracts only** — no bean/aspect ships here; add `summer-data-outbox` / `summer-data-audit` for behavior.
- `f8a.common.*` and `summer.http.logging.*` do nothing without `summer-rest` on the classpath (this module never `@EnableConfigurationProperties` them).

## Graph refs
- `class:core/src/main/java/io/f8a/summer/core/domain/types/ufid/Ufid.java:Ufid` — `core/src/main/java/io/f8a/summer/core/domain/types/ufid/Ufid.java`
- `class:core/src/main/java/io/f8a/summer/core/domain/types/txid/Txid.java:Txid` — `core/src/main/java/io/f8a/summer/core/domain/types/txid/Txid.java`
- `class:core/src/main/java/io/f8a/summer/core/domain/types/txid/TxidGenerator.java:TxidGenerator` — `core/src/main/java/io/f8a/summer/core/domain/types/txid/TxidGenerator.java`
- `class:core/src/main/java/io/f8a/summer/core/domain/types/txid/MachineIdResolver.java:MachineIdResolver` — `core/src/main/java/io/f8a/summer/core/domain/types/txid/MachineIdResolver.java`
- `class:core/src/main/java/io/f8a/summer/core/response/ApiResponse.java:ApiResponse` — `core/src/main/java/io/f8a/summer/core/response/ApiResponse.java`
- `class:core/src/main/java/io/f8a/summer/core/exception/ViewableException.java:ViewableException` — `core/src/main/java/io/f8a/summer/core/exception/ViewableException.java`
- `class:core/src/main/java/io/f8a/summer/core/webclient/WebClientBuilderFactory.java:WebClientBuilderFactory` — `core/src/main/java/io/f8a/summer/core/webclient/WebClientBuilderFactory.java`
- `file:core/src/main/java/io/f8a/summer/core/webclient/WebClientBuilderOptions.java` — `core/src/main/java/io/f8a/summer/core/webclient/WebClientBuilderOptions.java`
- `class:core/src/main/java/io/f8a/summer/core/masking/MaskingUtil.java:MaskingUtil` — `core/src/main/java/io/f8a/summer/core/masking/MaskingUtil.java`
- `class:core/src/main/java/io/f8a/summer/core/autoconfigure/CommonLibProperties.java:CommonLibProperties` — `core/src/main/java/io/f8a/summer/core/autoconfigure/CommonLibProperties.java`
- `file:core/src/main/java/io/f8a/summer/core/logging/HttpLoggingProperties.java` — `core/src/main/java/io/f8a/summer/core/logging/HttpLoggingProperties.java`
- `class:core/src/main/java/io/f8a/summer/core/outbox/OutboxService.java:OutboxService` — `core/src/main/java/io/f8a/summer/core/outbox/OutboxService.java`
- `file:core/src/main/java/io/f8a/summer/core/outbox/model/OutboxEvent.java` — `core/src/main/java/io/f8a/summer/core/outbox/model/OutboxEvent.java`
- `class:core/src/main/java/io/f8a/summer/core/audit/Audit.java:Audit` — `core/src/main/java/io/f8a/summer/core/audit/Audit.java`
- `class:core/src/main/java/io/f8a/summer/core/security/authentication/Member.java:Member` — `core/src/main/java/io/f8a/summer/core/security/authentication/Member.java`
- `file:core/src/main/java/io/f8a/summer/core/util/ObjectMapperUtil.java` — `core/src/main/java/io/f8a/summer/core/util/ObjectMapperUtil.java`
