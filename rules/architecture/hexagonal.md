---
id: rules/architecture/hexagonal
paths:
  - "**/*.java"
severity: high
tags: [architecture, hexagonal, ports-adapters]
---


# Hexagonal Architecture (Ports & Adapters)

## Goal

Domain isolated from framework. Tests run without infrastructure. Adapters are plug-and-play.

## Package layout

```
com.foo/
├── domain/                       # pure domain — no framework
│   ├── user/User.java
│   └── user/UserService.java
├── application/                  # orchestration / use cases
│   └── user/CreateUserUseCase.java
├── port/                         # interfaces
│   ├── in/CreateUserPort.java
│   └── out/UserRepositoryPort.java
└── adapter/
    ├── in/                       # driven by external (REST, Kafka)
    │   ├── web/UserController.java
    │   └── kafka/UserEventListener.java
    └── out/                      # drives external (DB, message bus)
        ├── persistence/UserJpaRepository.java
        └── messaging/UserEventPublisher.java
```

## Rules

| Layer | May depend on |
|-------|---------------|
| domain | nothing (pure Java) |
| port | domain |
| application | domain, port |
| adapter | application, port, framework |

Enforce with ArchUnit (see `arch-unit-check` skill).

## Example

```java
// domain/user/User.java
public record User(UserId id, EmailAddress email, String name) {}

// port/out/UserRepositoryPort.java
public interface UserRepositoryPort {
    Optional<User> findById(UserId id);
    User save(User user);
}

// application/user/CreateUserUseCase.java
public class CreateUserUseCase {
    private final UserRepositoryPort repo;

    public CreateUserUseCase(UserRepositoryPort repo) {
        this.repo = repo;
    }

    public User create(EmailAddress email, String name) {
        if (repo.findByEmail(email).isPresent()) {
            throw new DuplicateUserException(email.value());
        }
        return repo.save(new User(UserId.generate(), email, name));
    }
}

// adapter/in/web/UserController.java
@RestController
@RequiredArgsConstructor
public class UserController {
    private final CreateUserUseCase useCase;

    @PostMapping("/users")
    public UserResponse create(@RequestBody @Valid CreateUserRequest req) {
        User user = useCase.create(new EmailAddress(req.email()), req.name());
        return UserResponse.from(user);
    }
}

// adapter/out/persistence/UserJpaRepository.java
@Repository
@RequiredArgsConstructor
public class UserJpaAdapter implements UserRepositoryPort {
    private final SpringDataUserRepository jpa;

    @Override
    public Optional<User> findById(UserId id) {
        return jpa.findById(id.value()).map(this::toDomain);
    }

    @Override
    public User save(User user) {
        return toDomain(jpa.save(toEntity(user)));
    }
}
```

## Testing

Domain + application tests use mock adapters:

```java
class CreateUserUseCaseTest {
    UserRepositoryPort repo = mock(UserRepositoryPort.class);
    CreateUserUseCase useCase = new CreateUserUseCase(repo);

    @Test
    void shouldReject_whenDuplicate() {
        when(repo.findByEmail(any())).thenReturn(Optional.of(existingUser));
        assertThatThrownBy(() -> useCase.create(...))
            .isInstanceOf(DuplicateUserException.class);
    }
}
```

No Spring context, no Testcontainers. Fast.

## When NOT to use hexagonal

- Small CRUD service (< 10 endpoints) — overhead > benefit.
- Prototype/spike — over-engineering.
- Team unfamiliar with the pattern — start with feature-slice, evolve.

For these, see `package-layout.md` for alternatives.
