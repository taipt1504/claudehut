---
id: rules/architecture/ddd
applies-to: "**/*"
severity: medium
tags: [ddd, aggregate, value-object, domain-event]
---

# Domain-Driven Design Patterns

## Aggregate Root

- Single entity per aggregate that exposes operations to outside.
- Other entities/value objects within aggregate accessed ONLY via aggregate root.
- Transactional boundary = aggregate boundary.

```java
public class Order {  // aggregate root
    private OrderId id;
    private List<OrderLine> lines;  // not exposed mutably
    private OrderStatus status;

    public void addLine(Product product, int qty) {  // operation
        if (status != OrderStatus.DRAFT) throw new BusinessRuleException("not draft");
        lines.add(new OrderLine(product.id(), qty, product.price()));
    }

    public List<OrderLine> lines() { return List.copyOf(lines); }
}
```

Repositories work at aggregate root level only:

```java
public interface OrderRepository {
    Optional<Order> findById(OrderId id);
    Order save(Order order);
}
// NOT: orderLineRepository
```

## Value Object

- Immutable.
- Equality by value, not identity.
- Self-validating in constructor.

```java
public record EmailAddress(String value) {
    public EmailAddress {
        if (value == null || !value.matches(".+@.+\\..+"))
            throw new IllegalArgumentException("invalid email");
    }
}

public record Money(BigDecimal amount, Currency currency) {
    public Money {
        if (amount == null || currency == null) throw new IllegalArgumentException();
    }
    public Money plus(Money other) {
        if (!currency.equals(other.currency))
            throw new IllegalArgumentException("currency mismatch");
        return new Money(amount.add(other.amount), currency);
    }
}
```

## Domain Event

- Past-tense name (`OrderPlacedEvent`, `UserCreatedEvent`).
- Immutable record.
- Carries enough state for subscribers.

```java
public record OrderPlacedEvent(
    OrderId orderId,
    CustomerId customerId,
    Money total,
    Instant placedAt
) {}
```

Publish via Spring `ApplicationEventPublisher` OR outbox pattern for cross-service.

## Bounded Context

- Each bounded context = its own module / microservice.
- Shared kernel (translation) at edges only.
- Each context has its own ubiquitous language.

## Repository (DDD)

- Lives in domain or port layer (depending on hexagonal usage).
- Returns aggregate roots, not entities.
- Persists aggregates atomically.

## Anti-patterns

- Anemic domain model (entity = data + setters only, logic in services).
- Cross-aggregate transactional consistency (use eventual via events).
- Querying inner entity directly: `lineRepo.findByOrderAndProduct(...)` — query at aggregate.
- Domain depends on Spring (`@Entity`, `@Service`) — break framework leak.

## When to apply

DDD heaviness pays when:
- Complex domain logic (rules, workflows, invariants).
- Multiple stakeholder vocabularies.
- Long-lived service with evolving requirements.

Don't apply when:
- Simple CRUD.
- Anemic domain naturally.
- Team time-constrained.

## Tooling

- Modulith for in-process bounded contexts (Spring Modulith).
- Outbox + Kafka for cross-context events.
