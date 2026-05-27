# TDD Cycle — Worked Examples

## Table of contents

- [Example 1 — New service method](#example-1--new-service-method)
- [Example 2 — Bug fix](#example-2--bug-fix)
- [Example 3 — Reactive operator](#example-3--reactive-operator)

## Example 1 — New service method

**Task:** Add `UserService.create(CreateUserRequest)` that rejects duplicate email.

### RED

```java
// src/test/java/com/x/UserServiceTest.java
@Test
@DisplayName("rejects when email already exists")
void shouldRejectDuplicate_whenEmailExists() {
    when(userRepo.existsByEmail("a@b.com")).thenReturn(true);
    assertThatThrownBy(() -> userService.create(new CreateUserRequest("a@b.com", "Alice")))
        .isInstanceOf(DuplicateUserException.class)
        .hasMessageContaining("a@b.com");
}
```

Run:

```bash
./gradlew test --tests 'com.x.UserServiceTest.shouldRejectDuplicate_whenEmailExists'
```

Output:

```
NoSuchMethodError: UserService.create(CreateUserRequest)
```

Good — RED for the right reason (method doesn't exist).

### GREEN

```java
// src/main/java/com/x/UserService.java
public User create(CreateUserRequest req) {
    if (userRepo.existsByEmail(req.email())) {
        throw new DuplicateUserException(req.email());
    }
    return userRepo.save(new User(req.email(), req.name()));
}
```

Re-run:

```bash
./gradlew test --tests 'com.x.UserServiceTest'
```

All pass. Clean output.

### REFACTOR

The code is clean. Skip.

### Commit

```
feat(user): reject duplicate email on create

Throws DuplicateUserException when email already exists in repository.
Covered by UserServiceTest.shouldRejectDuplicate_whenEmailExists.
```

---

## Example 2 — Bug fix

**Bug:** `UserService.create` throws NPE when email is null instead of validation error.

### RED

```java
@Test
@DisplayName("rejects null email with IllegalArgumentException")
void shouldRejectNullEmail() {
    assertThatThrownBy(() -> userService.create(new CreateUserRequest(null, "Alice")))
        .isInstanceOf(IllegalArgumentException.class)
        .hasMessageContaining("email required");
}
```

Run:

```
NullPointerException at UserService.java:42 (current bug)
```

RED — but wrong exception type. The test correctly asserts the desired behavior.

### GREEN

```java
public User create(CreateUserRequest req) {
    if (req.email() == null || req.email().isBlank()) {
        throw new IllegalArgumentException("email required");
    }
    if (userRepo.existsByEmail(req.email())) {
        throw new DuplicateUserException(req.email());
    }
    return userRepo.save(new User(req.email(), req.name()));
}
```

Run: pass. Run neighbours: pass.

### REFACTOR

Could extract validation into a method, but the class is small. Skip.

### Commit

```
fix(user): reject null/blank email with IllegalArgumentException

Previously threw NullPointerException on null email field.
Covered by UserServiceTest.shouldRejectNullEmail.
```

---

## Example 3 — Reactive operator

**Task:** Add `UserHandler.findById(...)` returning `Mono<ServerResponse>`.

### RED

```java
@Test
void shouldReturn200_whenUserExists() {
    when(userRepo.findById("u1")).thenReturn(Mono.just(new User("u1", "a@b.com", "Alice")));

    webTestClient.get().uri("/users/u1")
        .exchange()
        .expectStatus().isOk()
        .expectBody().jsonPath("$.email").isEqualTo("a@b.com");
}

@Test
void shouldReturn404_whenUserNotFound() {
    when(userRepo.findById("u1")).thenReturn(Mono.empty());

    webTestClient.get().uri("/users/u1")
        .exchange()
        .expectStatus().isNotFound();
}
```

Run: fails — handler doesn't exist.

### GREEN

```java
public Mono<ServerResponse> findById(ServerRequest req) {
    String id = req.pathVariable("id");
    return userRepo.findById(id)
        .flatMap(user -> ServerResponse.ok().bodyValue(user))
        .switchIfEmpty(ServerResponse.notFound().build());
}
```

Plus router config.

Run: pass.

### REFACTOR

Add explicit `Mono<UserResponse>` mapping if domain leaks.

```java
public Mono<ServerResponse> findById(ServerRequest req) {
    String id = req.pathVariable("id");
    return userRepo.findById(id)
        .map(this::toResponse)
        .flatMap(resp -> ServerResponse.ok().bodyValue(resp))
        .switchIfEmpty(ServerResponse.notFound().build());
}

private UserResponse toResponse(User u) {
    return new UserResponse(u.id(), u.email(), u.name());
}
```

Run: pass. Behavior unchanged.

### Commit

```
feat(user): add WebFlux handler for GET /users/{id}

Returns 200 with UserResponse or 404 when user not found.
```
