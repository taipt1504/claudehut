---
id: rules/framework/contract-compat
paths:
  - "**/*.avsc"
  - "**/*.proto"
  - "**/*Controller.java"
  - "**/*Listener.java"
  - "**/*Producer.java"
  - "**/openapi*.yaml"
  - "**/openapi*.yml"
severity: high
tags: [contract, schema, kafka, avro, protobuf, rest, grpc, compatibility]
---
<!-- ClaudeHut rule template — generated into .claude/rules/framework/contract-compat.md by claudehut-init. -->


# Contract & schema compatibility

An event schema or public endpoint is a contract with independently-deployed consumers. A backward-incompatible
change breaks them silently at runtime. Evolve additively or version explicitly — never remove/rename/narrow
an existing required field on a live contract.

## DO

- Evolve schemas ADDITIVELY: new fields are OPTIONAL with a default (Avro `"default"`, proto optional). This
  keeps BACKWARD + FORWARD (i.e. FULL) compatibility.
- Give every event a schema version; make consumers TOLERANT of unknown fields (do not fail-fast on extra
  fields — `spring.json.trusted.packages` / `ErrorHandlingDeserializer`, Avro reader-schema tolerance).
- Add a consumer-driven / provider CONTRACT TEST for each new or changed event (Spring Cloud Contract or Pact)
  and each public REST/gRPC endpoint. It must fail when the contract breaks.
- Route consumer failures to a DLQ and assert the replay path with a test.
- For REST/OpenAPI: additive or versioned changes only (`/v2`, media-type version). Diff the committed spec
  with an oasdiff-style breaking-change check in CI.

## DON'T

- Remove or rename a required field, narrow a type (`long`→`int`, `string`→`enum`), or make an optional field
  required on an existing schema/endpoint.
- Reuse or reorder Protobuf field numbers; change a field's wire type.
- Remove a REST response field, add a required request param, or change the HTTP status / error body on an
  existing endpoint without a version bump.
- Ship a strict deserializer that throws on an unknown field (a producer's additive change then breaks you).
- Merge a schema change with no contract test — the break is invisible until a consumer fails in prod.

## Avro — compatible vs breaking

```json
// COMPATIBLE (additive optional with default)
{"name": "discountCode", "type": ["null", "string"], "default": null}

// BREAKING (removed/renamed required field, or type narrowing) — bump the subject version instead
```

## Protobuf

```proto
// SAFE: add a new field with a fresh number
optional string coupon = 7;
// BREAKING: reusing number 3 for a different field, or changing int64 -> int32
```

## Anti-patterns

- Renaming `customerId` → `custId` on a live Avro schema — every consumer breaks on the next deploy.
- A new `@KafkaListener` with no Spring Cloud Contract / Pact test — the producer can break it undetected.
- Removing a field from an OrderResponse DTO — mobile clients on the old contract 500.
- No DLQ on a listener — a poison message halts the partition.
