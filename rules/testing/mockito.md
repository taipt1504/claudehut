---
id: rules/testing/mockito
applies-to: "**/*Test.java"
severity: medium
tags: [mockito, mocking]
---

# Mockito Conventions

## DO

- Use `@ExtendWith(MockitoExtension.class)` + `@Mock` / `@InjectMocks`.
- Use BDD-style: `given(...).willReturn(...)`.
- Verify behavior, not implementation.
- Mock COLLABORATORS, not the system under test.

## DON'T

- Mock value objects (records, simple data classes).
- Mock framework types (Spring beans you don't own).
- Use `PowerMock` for static / final — refactor instead.
- `when(...).thenReturn(...)` followed by NO verification — orphan stubbing.
- Strict stubbing exceptions ignored — fix stubs.

## Setup

```java
@ExtendWith(MockitoExtension.class)
class UserServiceTest {

    @Mock UserRepository repo;
    @Mock EventPublisher events;
    @InjectMocks UserService service;  // SUT with auto-injected mocks

    @Test
    void shouldCreate() {
        when(repo.existsByEmail("a@b.com")).thenReturn(false);
        when(repo.save(any())).thenAnswer(i -> i.getArgument(0));

        User created = service.create(new CreateUserRequest("a@b.com", "Alice"));

        assertThat(created.email()).isEqualTo("a@b.com");
        verify(events).publish(any(UserCreatedEvent.class));
    }
}
```

## Argument matchers

```java
verify(repo).save(argThat(u -> u.email().equals("a@b.com")));

// Capture argument for detailed inspection
ArgumentCaptor<User> captor = ArgumentCaptor.forClass(User.class);
verify(repo).save(captor.capture());
assertThat(captor.getValue().name()).isEqualTo("Alice");
```

## Mockito modes

```java
@MockitoSettings(strictness = Strictness.STRICT_STUBS)  // default in Mockito 3+
```

Throws on:
- Unused stubbings (`when` without subsequent call).
- Mismatched stubbings.

Helps catch test bugs. Don't downgrade to LENIENT without reason.

## When NOT to mock

- Value types — use real instances.
- Pure functions / utilities — use directly.
- Spring `@Component` you don't own (autowired) — use real bean if integration test, mock if unit test.
- DTOs / records — never mock data.

## Stubbing void methods

```java
doThrow(new IllegalStateException("nope")).when(repo).delete(any());
doNothing().when(eventPublisher).publish(any());  // default, but explicit
```

## Anti-patterns

- Mocking the System Under Test.
- Mocking + verifying every call — implementation-coupled, brittle.
- `Mockito.spy(...)` without strong reason — confuses real vs stub behavior.
- Stubbing then not using → strict-stubs catches.
- Mocking `LocalDateTime.now()` via PowerMock — inject `Clock` instead.

## Better than mocks

- Fake implementations (in-memory repo) for repository pattern tests.
- Real dependencies via `@SpringBootTest` + `@MockBean` (sparingly).
- Stub via interface implementation, not framework mock.
