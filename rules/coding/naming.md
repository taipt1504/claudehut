---
id: rules/coding/naming
applies-to: "**/*.java"
severity: medium
tags: [naming, conventions]
---

# Java Naming Conventions

## DO

- **Classes** — PascalCase, noun phrases: `UserService`, `OrderRepository`, `PaymentEvent`.
- **Methods** — camelCase, verb phrases: `createUser`, `findByEmail`, `publishEvent`.
- **Constants** — `UPPER_SNAKE_CASE`: `MAX_RETRIES`, `DEFAULT_TIMEOUT_MS`.
- **Packages** — lowercase, dot-separated, singular: `com.foo.user`, `com.foo.payment.event`.
- **Fields** — camelCase, descriptive: `userEmail`, `createdAt`.
- **Type parameters** — single uppercase letter, or descriptive: `T`, `K`, `V`, `Request`, `Response`.
- **Boolean** — predicate verb: `isActive`, `hasPermission`, `canRetry`.

## DON'T

- Hungarian notation: `strUserEmail`, `intRetries` — Java types are visible.
- Abbreviations: `usrSvc` → use `userService`.
- Single-letter identifiers (except loop indices, type params): `String s` → `String email`.
- `Util`/`Helper`/`Manager` suffix without specifics: `StringHelper` → `EmailValidator`.
- Plural package names: `com.foo.users` → `com.foo.user`.
- Generic test names: `testIt`, `test1` → `shouldRejectDuplicate_givenExistingEmail`.

## Specific to ClaudeHut stack

| Layer | Suffix | Example |
|-------|--------|---------|
| REST controller (MVC) | `Controller` | `UserController` |
| Handler (WebFlux) | `Handler` | `UserHandler` |
| Service | `Service` | `UserService` |
| Repository | `Repository` | `UserRepository` |
| MapStruct mapper | `Mapper` | `UserMapper` |
| DTO inbound | `Request` | `CreateUserRequest` |
| DTO outbound | `Response` | `UserResponse` |
| Event | `Event` | `UserCreatedEvent` |
| Exception (domain) | `Exception` | `DuplicateUserException` |
| Configuration | `Config` or `Configuration` | `KafkaConfig` |
| Test | `Test` (unit) or `IT` (integration) | `UserServiceTest`, `UserApiIT` |

## Test method names

Pattern: `should<expected>_when<condition>_given<state>` or use `@DisplayName` for readability:

```java
@Test
@DisplayName("rejects duplicate when email already exists in repository")
void shouldRejectDuplicate_whenEmailExists() { ... }
```

## Anti-patterns

- `ServiceImpl` for the only impl — drop the suffix; interface unnecessary.
- `IUserService` interface prefix — use `UserService` interface + `DefaultUserService` impl if needed.
- Cryptic acronyms in domain: `Pmt`, `Inv` → `Payment`, `Invoice`.
