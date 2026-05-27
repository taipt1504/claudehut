# R2DBC Converters

## When needed

R2DBC drivers translate primitive + standard types automatically. Custom types (enums, value objects, JSON columns) need explicit converters.

## Enum

R2DBC stores enums as strings by default. To customize:

```java
@WritingConverter
public class StatusToStringConverter implements Converter<OrderStatus, String> {
    @Override
    public String convert(OrderStatus source) {
        return source.name();
    }
}

@ReadingConverter
public class StringToStatusConverter implements Converter<String, OrderStatus> {
    @Override
    public OrderStatus convert(String source) {
        return OrderStatus.valueOf(source);
    }
}
```

Register:

```java
@Configuration
public class R2dbcConfig extends AbstractR2dbcConfiguration {
    @Override
    public ConnectionFactory connectionFactory() { ... }

    @Override
    protected List<Object> getCustomConverters() {
        return List.of(
            new StatusToStringConverter(),
            new StringToStatusConverter()
        );
    }
}
```

## UUID

Postgres has native UUID; driver handles. For other DBs, may need converter:

```java
@WritingConverter
public class UuidToBytesConverter implements Converter<UUID, byte[]> {
    public byte[] convert(UUID source) {
        ByteBuffer bb = ByteBuffer.allocate(16);
        bb.putLong(source.getMostSignificantBits());
        bb.putLong(source.getLeastSignificantBits());
        return bb.array();
    }
}
```

## JSON column (Postgres jsonb)

```java
@WritingConverter
public class JsonToStringConverter implements Converter<Map<String, Object>, String> {
    private final ObjectMapper mapper;
    public String convert(Map<String, Object> source) {
        try { return mapper.writeValueAsString(source); }
        catch (JsonProcessingException e) { throw new RuntimeException(e); }
    }
}
```

Use `Json` type from `io.r2dbc.postgresql.codec.Json` for direct binding.

## Value object

```java
public record EmailAddress(String value) {}

@WritingConverter
public class EmailToStringConverter implements Converter<EmailAddress, String> {
    public String convert(EmailAddress source) { return source.value(); }
}

@ReadingConverter
public class StringToEmailConverter implements Converter<String, EmailAddress> {
    public EmailAddress convert(String source) { return new EmailAddress(source); }
}
```

## Anti-patterns

- Storing serialized objects as VARCHAR — use proper types or JSON column.
- Custom converter for primitive (Integer, String, Long) — drivers handle.
- Forgetting both `@WritingConverter` AND `@ReadingConverter` — half-mapping.
- Converter throwing checked exception — wrap with RuntimeException.
