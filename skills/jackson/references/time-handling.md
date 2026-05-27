# Jackson Time Handling

## JavaTimeModule registration

Required for `Instant`, `LocalDateTime`, `LocalDate`, `ZonedDateTime`, etc.

```java
ObjectMapper mapper = new ObjectMapper();
mapper.registerModule(new JavaTimeModule());
```

In Spring Boot 3.x: auto-registered.

## Default format (after registration)

| Type | JSON output |
|------|-------------|
| `Instant` | `"2025-05-27T10:00:00Z"` |
| `LocalDateTime` | `"2025-05-27T10:00:00"` (no zone) |
| `LocalDate` | `"2025-05-27"` |
| `LocalTime` | `"10:00:00"` |
| `ZonedDateTime` | `"2025-05-27T10:00:00+07:00[Asia/Ho_Chi_Minh]"` |
| `OffsetDateTime` | `"2025-05-27T10:00:00+07:00"` |
| `Duration` | `"PT15M"` (ISO 8601) |
| `Period` | `"P1Y2M3D"` |

## Disable timestamp serialization

```java
mapper.disable(SerializationFeature.WRITE_DATES_AS_TIMESTAMPS);
```

If enabled (default in plain Jackson), `Instant` → `{"epochSecond": 1716800400, "nano": 0}`.

## Custom format per field

```java
public record Event(
    @JsonFormat(shape = JsonFormat.Shape.STRING, pattern = "yyyy-MM-dd HH:mm:ss")
    LocalDateTime occurredAt
) {}
```

Better: configure module-wide if pattern is project-wide.

## Time zone handling

Spring Boot 3.x default: serialize without zone if not specified. To force UTC:

```java
.timeZone(TimeZone.getTimeZone("UTC"))
```

Recommendation:
- Store in DB as `TIMESTAMP WITH TIME ZONE` (Postgres `timestamptz`).
- Map to `Instant` in Java (always UTC).
- Display in user's local zone at presentation layer only.

## Recommended config

```java
@Bean
public Jackson2ObjectMapperBuilderCustomizer customizer() {
    return builder -> builder
        .featuresToDisable(SerializationFeature.WRITE_DATES_AS_TIMESTAMPS)
        .featuresToDisable(SerializationFeature.WRITE_DURATIONS_AS_TIMESTAMPS)
        .modulesToInstall(new JavaTimeModule())
        .timeZone(TimeZone.getTimeZone("UTC"));
}
```

## Old API (Date, Calendar)

`java.util.Date` works without extra config (legacy). But prefer `Instant`:

```java
// Avoid
private Date createdAt;

// Prefer
private Instant createdAt;
```

`Calendar` → never; legacy + mutable.

## Parsing leniency

Strict ISO 8601:

```java
.featuresToEnable(DeserializationFeature.FAIL_ON_INVALID_TIME_FORMAT)
```

Lenient (default): tries common formats.

## Anti-patterns

- Skip `JavaTimeModule` → `Instant` serialized as `{epochSecond, nano}` object
- `Date` instead of `Instant` → legacy + mutable + zone confusion
- `LocalDateTime` (no zone) for timestamps → ambiguous across deployments
- `@JsonFormat` pattern per-field everywhere → inconsistent; move to module config
- Store as VARCHAR in DB → loses index usability, sort breaks
