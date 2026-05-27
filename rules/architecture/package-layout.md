---
id: rules/architecture/package-layout
paths:
  - "**/*"
severity: high
tags: [architecture, layout]
---


# Package Layout Rule

Choose ONE layout. Don't mix. Document the choice in `.claudehut/memory/conventions.md`.

## Option A — Feature-slice (recommended for most projects)

```
com.foo/
├── user/                    # feature module
│   ├── UserController.java
│   ├── UserService.java
│   ├── UserRepository.java
│   ├── UserMapper.java
│   ├── domain/UserId.java
│   ├── dto/CreateUserRequest.java
│   └── dto/UserResponse.java
├── payment/
│   ├── PaymentController.java
│   ├── PaymentService.java
│   └── ...
└── common/                  # cross-cutting
    ├── config/
    ├── exception/
    └── util/
```

**Pro:** colocates change-coupled code. Easy onboarding per feature.
**Con:** cross-feature imports if not careful.

## Option B — Hexagonal (Ports & Adapters)

```
com.foo/
├── domain/                  # pure domain logic, no framework
│   ├── user/User.java
│   └── user/UserService.java
├── application/             # use cases / orchestration
│   └── user/CreateUserUseCase.java
├── adapter/
│   ├── in/                  # inbound adapters
│   │   ├── web/UserController.java
│   │   └── kafka/UserEventListener.java
│   └── out/                 # outbound adapters
│       ├── persistence/UserJpaRepository.java
│       └── messaging/UserEventPublisher.java
└── port/                    # interfaces
    ├── in/CreateUserPort.java
    └── out/UserRepositoryPort.java
```

**Pro:** strict layering. Testable without infrastructure.
**Con:** more boilerplate; harder to navigate for small features.

Verify with ArchUnit: domain → no framework imports.

## Option C — Layered (legacy / simple CRUD)

```
com.foo/
├── controller/
├── service/
├── repository/
├── dto/
└── entity/
```

**Pro:** flat. Familiar.
**Con:** scales poorly. Change-coupling spread across packages.

Only use for small services (< 20 endpoints) or porting legacy.

## Rules across all layouts

- **Domain doesn't depend on framework.** No `@RestController`, `@Service` in domain classes.
- **DTOs don't reach the domain layer.** Use mappers at boundaries.
- **Tests mirror main packages**: `src/test/java/com/foo/user/UserServiceTest.java`.
- **Integration tests separate source set** if Gradle: `src/integrationTest/java/...`.

## Enforcement

Add ArchUnit test enforcing the chosen layout. ClaudeHut Phase Loop reviewer-style runs this if configured.

```java
@AnalyzeClasses(packages = "com.foo")
class ArchitectureTest {
  @ArchTest
  static final ArchRule domain_independent = noClasses()
    .that().resideInAPackage("..domain..")
    .should().dependOnClassesThat().resideInAnyPackage("..adapter..", "..application..");
}
```
