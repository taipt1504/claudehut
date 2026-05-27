---
id: rules/testing/given-when-then
applies-to: "**/*Test.java"
severity: low
tags: [test-naming, structure]
---

# Given/When/Then Test Structure

## Format

```java
@Test
void shouldXxx_whenYyy_givenZzz() {
    // GIVEN
    when(repo.existsByEmail("a@b.com")).thenReturn(true);

    // WHEN
    Throwable thrown = catchThrowable(() ->
        service.create(new CreateUserRequest("a@b.com", "Alice")));

    // THEN
    assertThat(thrown).isInstanceOf(DuplicateUserException.class)
        .hasMessageContaining("a@b.com");
}
```

## Or use AssertJ BDD-style

```java
@Test
@DisplayName("rejects when email already exists")
void shouldRejectDuplicate() {
    given(repo.existsByEmail("a@b.com")).willReturn(true);

    assertThatThrownBy(() -> service.create(new CreateUserRequest("a@b.com", "Alice")))
        .isInstanceOf(DuplicateUserException.class);
}
```

## Naming

- `should<expected>_when<condition>_given<state>` — explicit and IDE-friendly.
- OR `@DisplayName` for readability when method name is convoluted.
- Both are fine; pick one per project and stick with it.

## Sections

| Section | Content |
|---------|---------|
| GIVEN | Preconditions: mock setup, fixture data, system state |
| WHEN | The single action under test |
| THEN | Assertions on outcome (return value, exception, side effect) |

## Anti-patterns

- Multiple WHEN steps in one test — split into multiple tests.
- THEN that asserts non-deterministic things — refactor to make deterministic.
- GIVEN that takes 20 lines — extract to helper or `@BeforeEach`.
- No clear section comments — even if not labeled, structure should be obvious.

## Acceptance criteria mapping

Each AC from contract → one test:

```
AC-1: GIVEN user u1 has no purchases WHEN GET /users/me/purchases THEN 200 + empty array
```

Becomes:

```java
@Test
@DisplayName("AC-1: returns empty array when user has no purchases")
void shouldReturnEmpty_whenNoPurchases_givenNewUser() { ... }
```

Phase 3 plan-spec-coverage script verifies every AC has a test.
