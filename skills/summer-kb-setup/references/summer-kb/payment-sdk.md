# payment-sdk — summer-payment-sdk
> Consumer-facing: yes · Auto-config: manual dep · Depends on: core

## TL;DR
- Types-only library: annotate your DTOs/events and (de)serialize the sealed contracts with your own `ObjectMapper` — nothing is added to the Spring context.
- `@UfidPrefix`/`@JE`/`@TX`/`@SE`/`@Compact`/`@UInt128` are `@JacksonAnnotationsInside` meta-annotations that swap in `Ufid` (de)serializers per field.
- Sealed roots (`VaEvent`, `WalletEvent`, `WalletCommand`, `PaymentIntentCommand`, …) are the authoritative Kafka wire contracts, discriminated by a `"type"` JSON field for exhaustive `switch`.

## Activate
| | |
|---|---|
| AutoConfiguration | — none (no `META-INF/spring/*.AutoConfiguration.imports`, no `@Configuration`) |
| Gate property | — none; activation = importing the types |
| Gradle coordinate | `io.f8a.summer:summer-payment-sdk` (manual `implementation`; version `0.3.26` ← `gradle.properties:paymentSdkVersion`) |

Note: `api project(":summer-core")` is transitive (provides `Ufid`/`UfidDisplay`/`Txid`); `jackson-databind` + `jakarta.validation` are `compileOnly` here — the consumer must supply them at runtime (every WebFlux service does).

## Config keys
None — types/utilities only.

## Public API
| Type | Kind | When to use |
|---|---|---|
| `UfidPrefix` | meta-annotation, `String value()` | Annotate a `Ufid` field to emit/parse `<prefix><display>` JSON with an ad-hoc prefix (e.g. `@UfidPrefix("AC")`) |
| `JE` / `TX` / `SE` | `@UfidPrefix` aliases (`"JE"`/`"TX"`/`"SE"`) | Annotate a `Ufid` field that is a Journal-Entry / Transaction / Settlement id |
| `Compact` | annotation → 26-char Crockford Base32 | Emit a `Ufid` as a compact string (short URL/token form) |
| `UInt128` | annotation → decimal uint128 | Emit a `Ufid` as decimal uint128 for TigerBeetle interop |
| `VaEvent` | sealed interface (topic `va.events`) | Consume/produce VA lifecycle events (va-ms → payment-orchestrator-ms) |
| `WalletEvent` | sealed interface (topic `wallet.events`) | Consume/produce wallet saga events (wallet-ms → payment-orchestrator-ms) |
| `WalletCommand` | sealed interface (topic `wallet.commands`) | Send/handle limit-hold commit/release commands (payment-orchestrator-ms → wallet-ms) |
| `PaymentIntentCommand` | sealed interface (`TOPIC` const) | Send/handle payment-intent commands (back-office/scheduler → payment-orchestrator-ms) |
| `LedgerAccountId` | record wrapping a `UUID` | Mint/parse a strongly-typed ledger account id from CIF + account type |
| `LedgerAccountType` | enum (`getLedgerCode()`) | Supply the 3-digit type code to `LedgerAccountId.generate` |

Sealed permits (edit `permits` + `@JsonSubTypes` together to add a variant):
- `VaEvent` → `VaCreatedEvent`(`va.created`), `VaReservedEvent`(`va.reserved`), `VaReservationRejectedEvent`(`va.reservation.rejected`), `VaReleasedEvent`(`va.released`), `VaMarkedPaidEvent`(`va.marked.paid`), `VaCanceledEvent`(`va.canceled`), `VaCreditReceivedEvent`(`va.credit.received`)
- `WalletEvent` → `PaymentIntentInitiatedEvent`(`payment.intent.initiated`), `LimitHeldEvent`(`limit.held`), `LimitCommittedEvent`(`limit.committed`), `LimitReleasedEvent`(`limit.released`)
- `WalletCommand` → `CommitLimitHoldCommand`(`commit.limit.hold`), `ReleaseLimitHoldCommand`(`release.limit.hold`)
- `PaymentIntentCommand` → `MerchantSettlementCommand`(`merchant.settlement`); `String TOPIC = "payment.intent.cmd.v1"`

## Usage
```java
// Annotate Ufid fields to control JSON shape (annotation supplies both serializers).
public record TransferDto(
    @TX Ufid transactionId,           // JSON: "TX<display>"
    @UfidPrefix("AC") Ufid accountId, // JSON: "AC<display>"
    @UInt128 Ufid tbTransferId) {}     // JSON: "3402..." decimal uint128

// Consume a sealed contract: read the root, exhaustive-switch on the subtype.
WalletEvent evt = objectMapper.readValue(record.value(), WalletEvent.class); // reads "type"
switch (evt) {
  case PaymentIntentInitiatedEvent e -> startSaga(e);
  case LimitHeldEvent e -> onHeld(e);
  case LimitCommittedEvent e -> onCommitted(e);
  case LimitReleasedEvent e -> onReleased(e);
}

// Ledger account id: mint from CIF + type, or parse from wire/path.
LedgerAccountId acct = LedgerAccountId.generate(cifId, LedgerAccountType.WALLET);
LedgerAccountId parsed = LedgerAccountId.of(pathVar); // accepts UUID hex OR CIF10-TYPE3-RAND15
```

## Gotchas
- `jackson-databind` + `jakarta.validation` are `compileOnly` — the SDK contributes no runtime Jackson; annotations do nothing on a mapper that never touches the field.
- A bare `Ufid` field (no annotation) is NOT handled by these serializers — `UfidSerializer.createContextual` reads `UfidPrefix.value()` off the property; unannotated fields fall through to default Jackson.
- `UfidDeserializer` throws `IOException("Expected UFID with prefix '<p>', got: <value>")` on prefix mismatch — serialize and deserialize a field with the *same* annotation on both sides.
- `@Compact` (Crockford Base32, 26 chars) and `@UInt128` (decimal) are different wire formats — a field written with one cannot be read with the other.
- Sealed contracts are exhaustive-by-compiler: adding a variant means editing BOTH the `permits` list and the `@JsonSubTypes` array in the same file; consumer `switch` then fails to compile until updated. All roots set `@JsonIgnoreProperties(ignoreUnknown = true)` for forward-compat.
- `"type"` discriminator strings ARE the wire contract (`va.created`, `limit.held`, `commit.limit.hold`, `merchant.settlement`, …) — never rename.
- Interface-level accessors differ: `VaEvent` exposes only `vaId()` + `occurredAt()` (no `sagaId()` — VA_CREATED/VA_CANCELED/VA_CREDIT_RECEIVED are pre-saga); `WalletEvent` adds `sagaId()` + `intentId()`; `WalletCommand` also adds `holdId()`.
- `PaymentIntentCommand.TOPIC` constant is `"payment.intent.cmd.v1"` (the class Javadoc says `payment.intent.command.v1`; trust the constant).
- `LedgerAccountId` packs 10-digit CIF (40 bits) + 3-digit type (12 bits, `TYPE_CAP=1000`, caps at 999) + 76-bit `SecureRandom` into a `UUID`. `generate` requires exactly 10 CIF digits (`CIF_PATTERN=\d{10}`, `MAX_CIF=9_999_999_999`) and throws if `LedgerAccountType.getLedgerCode()` ≥ 1000.
- `LedgerAccountId` Jackson value is the readable `CIF10-TYPE3-RAND15` form (`@JsonValue toJson()`); `of(String)`/`fromJsonValue` also accept plain UUID hex. For Spring path/param binding register a `Converter<String, LedgerAccountId>` delegating to `of(String)` — not provided by the SDK.

## Graph refs
- `file:payment-sdk/src/main/java/io/f8a/summer/payment/annotation/UfidPrefix.java`
- `file:payment-sdk/src/main/java/io/f8a/summer/payment/annotation/JE.java`
- `file:payment-sdk/src/main/java/io/f8a/summer/payment/annotation/TX.java`
- `file:payment-sdk/src/main/java/io/f8a/summer/payment/annotation/SE.java`
- `file:payment-sdk/src/main/java/io/f8a/summer/payment/annotation/Compact.java`
- `file:payment-sdk/src/main/java/io/f8a/summer/payment/annotation/UInt128.java`
- `class:payment-sdk/src/main/java/io/f8a/summer/payment/serialize/UfidSerializer.java:UfidSerializer`
- `class:payment-sdk/src/main/java/io/f8a/summer/payment/serialize/UfidDeserializer.java:UfidDeserializer`
- `class:payment-sdk/src/main/java/io/f8a/summer/payment/event/va/VaEvent.java:VaEvent`
- `class:payment-sdk/src/main/java/io/f8a/summer/payment/event/wallet/WalletEvent.java:WalletEvent`
- `class:payment-sdk/src/main/java/io/f8a/summer/payment/event/wallet/WalletCommand.java:WalletCommand`
- `class:payment-sdk/src/main/java/io/f8a/summer/payment/cmd/intent/PaymentIntentCommand.java:PaymentIntentCommand`
- `class:payment-sdk/src/main/java/io/f8a/summer/payment/domain/LedgerAccountId.java:LedgerAccountId`
- `class:payment-sdk/src/main/java/io/f8a/summer/payment/domain/LedgerAccountType.java:LedgerAccountType`
- `file:payment-sdk/build.gradle`
