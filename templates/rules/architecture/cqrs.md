---
id: rules/architecture/cqrs
paths:
  - "**/*.java"
severity: medium
tags: [cqrs, command, query]
---
<!-- ClaudeHut rule template — generated into .claude/rules/architecture/cqrs.md by claudehut-init. Reused & enhanced from committed rules/architecture/cqrs.md. -->


# CQRS — Command/Query Responsibility Segregation

## Principle

Split read and write models:

- **Commands** mutate state. Return void or acknowledgment, not data.
- **Queries** return data. Don't mutate state. Free to use denormalized read model.

## Light-weight CQRS (single DB)

```java
// Command side
public class CreateUserCommand {
    private final CreateUserCommandHandler handler;

    public UserId execute(CreateUserCommand cmd) {
        validate(cmd);
        User user = new User(UserId.generate(), cmd.email(), cmd.name());
        userRepo.save(user);
        events.publish(new UserCreatedEvent(user.id(), cmd.email()));
        return user.id();
    }
}

// Query side (separate read model)
public interface UserQueryService {
    Optional<UserView> get(UserId id);
    PageResult<UserSummary> search(SearchCriteria criteria);
}
```

## Heavy CQRS (separate read store)

- Writes → SQL DB (with strong consistency).
- Reads → denormalized projection (Elasticsearch, Redis cache, read-replica).
- Projection updated via event listener.

```java
@KafkaListener(topics = "user.created")
public void onUserCreated(UserCreatedEvent event) {
    userProjection.upsert(UserView.from(event));
}
```

## When to use

- Read/write asymmetry: 100× more reads than writes.
- Reads need denormalized shape that writes can't satisfy efficiently.
- Reporting / analytics workload.

## When NOT

- Simple CRUD with balanced read/write.
- Single source of truth required for both reads and writes (no eventual consistency tolerated).

## Anti-patterns

- CQRS without clear benefit — overhead from event plumbing.
- Read model lagging consistently → user confusion.
- Query handler also mutates (defeats split).
- Command returning detailed data (use separate query after).

## Combine with hexagonal

- Each command/query handler = use case (application layer).
- Read model adapter = OUT adapter.
- Write model adapter = OUT adapter.
- Both behind ports.
