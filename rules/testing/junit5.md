---
id: rules/testing/junit5
paths:
  - "**/*Test.java"
severity: medium
tags: [junit5, jupiter, test]
---


# JUnit 5 Conventions

## DO

- Use Jupiter API (`org.junit.jupiter.api.*`).
- `@DisplayName` for readability when method name is convoluted.
- Parameterized tests via `@ParameterizedTest` + `@MethodSource` / `@CsvSource`.
- Nested test classes via `@Nested` for grouping.
- Lifecycle: `@BeforeAll` (static), `@BeforeEach`, `@AfterEach`, `@AfterAll`.
- AssertJ for assertions (`assertThat`).

## DON'T

- JUnit 4 (`org.junit.Test`).
- Hamcrest (`assertThat(value, is(...))`) — AssertJ is clearer.
- Test name `test1`, `testIt` — name for behavior.
- Reuse mutable state across tests without reset.

## Examples

### Simple test

```java
@Test
void shouldRejectDuplicate_whenEmailExists() {
    when(repo.existsByEmail("a@b.com")).thenReturn(true);
    assertThatThrownBy(() -> service.create(new CreateUserRequest("a@b.com", "Alice")))
        .isInstanceOf(DuplicateUserException.class);
}
```

### Parameterized

```java
@ParameterizedTest(name = "should reject email {0}")
@ValueSource(strings = {"", " ", "no-at-sign", "@nodomain", "no@.tld"})
void shouldRejectInvalidEmail(String email) {
    assertThatThrownBy(() -> new EmailAddress(email))
        .isInstanceOf(IllegalArgumentException.class);
}

@ParameterizedTest
@CsvSource({
    "100,USD,100,EUR,error",
    "100,USD, 50,USD,150",
    "  0,USD,  0,USD,  0"
})
void moneyArithmetic(BigDecimal a, String aCur, BigDecimal b, String bCur, String expected) {
    var money1 = new Money(a, Currency.getInstance(aCur));
    var money2 = new Money(b, Currency.getInstance(bCur));
    if (expected.equals("error")) {
        assertThatThrownBy(() -> money1.plus(money2)).isInstanceOf(IllegalArgumentException.class);
    } else {
        assertThat(money1.plus(money2).amount()).isEqualByComparingTo(expected);
    }
}
```

### Nested grouping

```java
class UserServiceTest {

    @Nested
    @DisplayName("create")
    class Create {
        @Test void shouldSucceed() { ... }
        @Test void shouldRejectDuplicate() { ... }
        @Test void shouldValidateEmail() { ... }
    }

    @Nested
    @DisplayName("delete")
    class Delete {
        @Test void shouldRemoveExisting() { ... }
        @Test void shouldNoOp_whenNotFound() { ... }
    }
}
```

### Lifecycle

```java
@BeforeAll
static void initShared() {
    container.start();
}

@BeforeEach
void resetState() {
    jdbcTemplate.execute("TRUNCATE users CASCADE");
}

@AfterEach
void cleanup() { ... }

@AfterAll
static void teardown() {
    container.stop();
}
```

## Test naming

Format: `should<expected>_when<condition>_given<state>` OR use `@DisplayName`.

```java
@Test
@DisplayName("Returns 404 when user not found")
void getReturns404IfMissing() { ... }
```

## Anti-patterns

- Sleeping in tests (`Thread.sleep(2000)`) — use Awaitility or virtual time.
- Tests with multiple unrelated assertions — split into multiple tests.
- Order-dependent tests — use `@TestMethodOrder` only when truly needed.
- `@Disabled` without ticket comment — explain why it's disabled.
- Catching exception to assert it didn't happen — let it fail; cleaner output.
