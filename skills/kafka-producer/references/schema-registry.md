# Schema Registry

## Why

JSON without schema → producer + consumer drift → consumer breaks on field rename or removal. Schema Registry (Confluent / Apicurio) enforces schema compatibility checks before publish.

## Avro + Schema Registry

```yaml
spring:
  kafka:
    producer:
      key-serializer: io.confluent.kafka.serializers.KafkaAvroSerializer
      value-serializer: io.confluent.kafka.serializers.KafkaAvroSerializer
      properties:
        schema.registry.url: http://schema-registry:8081
        auto.register.schemas: false  # require explicit registration in CI
        use.latest.version: true
```

## Compatibility modes

| Mode | Producer can | Consumer must |
|------|--------------|----------------|
| BACKWARD | Read old data | Update consumer first |
| FORWARD | Read new data | Update producer first |
| FULL | Both | Either order |
| NONE | – | – |
| BACKWARD_TRANSITIVE | Read ALL old | Update consumer first |

For event-driven systems with many consumers: `BACKWARD` (default).

## Allowed changes (BACKWARD)

- Add optional field with default value.
- Remove optional field.
- Add new value to union.

## Forbidden changes (BACKWARD)

- Add required field (breaks existing consumers).
- Remove required field (breaks NEW consumers reading OLD data).
- Change field type (e.g., int → string).
- Rename field (treated as remove + add).

## Schema in CI

```bash
# Validate new schema against latest registered
mvn confluent:test-compatibility -Dschema.subject=order-value
```

CI fails if breaking change. Forces explicit schema bump.

## Without Schema Registry

If using JSON (no schema infra):
- Pin exact DTO classes between producer + consumer (versioned in shared lib).
- Bump shared lib version per breaking change.
- Use `@JsonIgnoreProperties(ignoreUnknown = true)` on consumer DTOs.
- Document compatibility contract in event topic README.

## JSON Schema (alternative to Avro)

If team prefers JSON over binary, Confluent supports JSON Schema in Schema Registry:

```yaml
value-serializer: io.confluent.kafka.serializers.json.KafkaJsonSchemaSerializer
```

Same compatibility checks; JSON payload. Slower than Avro but human-readable.
