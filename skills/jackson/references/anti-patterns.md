# Jackson Anti-Patterns

## Security

| Anti-pattern | Why bad | Fix |
|--------------|---------|-----|
| `mapper.enableDefaultTyping()` / `activateDefaultTyping()` | RCE via class FQCN in JSON | NEVER use; whitelist subtypes via `@JsonSubTypes` |
| `@JsonTypeInfo(use = Id.CLASS)` without `@JsonSubTypes` | Same RCE vector | Use `Id.NAME` + explicit subtype list |
| `Object` field type in DTO | Accepts ANY payload shape | Specific types or sealed hierarchy |
| `Map<String, Object>` for inbound DTO | Unstructured input | Explicit DTO |
| Custom deserializer calling `Class.forName(userInput)` | RCE | Whitelist registry of allowed types |
| `@RequestBody Entity` (mass assignment) | Client overrides any field | Use `*Request` DTO with explicit fields |

## Config

| Anti-pattern | Why bad | Fix |
|--------------|---------|-----|
| `new ObjectMapper()` without config | No JavaTimeModule, default typing risk | Use Spring's autoconfigured `ObjectMapper` |
| Skip `JavaTimeModule` registration | `Instant`/`LocalDateTime` serialized as objects | Register module |
| `WRITE_DATES_AS_TIMESTAMPS = true` | Loses ISO 8601 readability | Disable; use ISO strings |
| `FAIL_ON_UNKNOWN_PROPERTIES = false` on strict API | Silent accept of typo'd fields | Enable for inbound DTOs |
| `FAIL_ON_UNKNOWN_PROPERTIES = true` on event consumer | Breaks forward-compat | Disable for outbound message consumers |
| Different mapper config tests vs prod | Bug only in prod | Same `Jackson2ObjectMapperBuilderCustomizer` |
| Multiple `ObjectMapper` beans without `@Primary` | Spring picks unpredictably | Mark one `@Primary` or qualify by name |

## DTO design

| Anti-pattern | Why bad | Fix |
|--------------|---------|-----|
| `@JsonAnyGetter`/`@JsonAnySetter` everywhere | Schema unclear; consumer can't validate | Explicit fields |
| `@JsonInclude(NON_NULL)` not set on Response DTO | Sends `null` fields unnecessarily | Set globally or per-DTO |
| Domain entity used as response | Lazy loading exception on serialization | Map to Response DTO |
| Mutable DTO with setters when fields immutable | Inconsistent API | Use record |
| `@JsonProperty` everywhere on same-named fields | Noise | Only annotate on rename |
| Inheritance for "shared fields" | Jackson polymorphism complexity | Composition or duplicate fields |

## Time handling

| Anti-pattern | Why bad | Fix |
|--------------|---------|-----|
| `Date` field instead of `Instant` | Mutable + legacy | Use `Instant` |
| `LocalDateTime` for timestamps | No zone info → ambiguous | Use `Instant` (UTC) or `ZonedDateTime` |
| Store time as VARCHAR in DB | Loses index/sort | Use `timestamptz` (Postgres) |
| Per-field `@JsonFormat(pattern)` everywhere | Inconsistent + repeated | Configure module-wide |

## Performance

| Anti-pattern | Why bad | Fix |
|--------------|---------|-----|
| `new ObjectMapper()` per request | Expensive instantiation | Reuse singleton bean |
| Streaming large JSON via `writeValueAsString` | Loads entire string in memory | Use `JsonGenerator` for streaming |
| Deeply nested DTO (> 10 levels) | Slow + stack risk | Flatten or paginate |
| Sending raw entity tree (lazy fields) | N+1 + LazyInitializationException | Project to DTO before serialization |

## Polymorphism

| Anti-pattern | Why bad | Fix |
|--------------|---------|-----|
| `@JsonTypeInfo(use=Id.CLASS)` | Exposes Java FQCN in JSON; RCE vector | Use `Id.NAME` + `@JsonSubTypes` |
| Missing `@JsonTypeInfo` on inheritance | Subtype info lost at deser | Add `@JsonTypeInfo` with named subtypes |
| `defaultImpl = SomeClass.class` without rationale | Unknown subtype silently becomes default | Either fail-fast or document why default |
| Single subtype in `@JsonSubTypes` | Polymorphism not needed | Use plain class |
