# R2DBC Reactive Transactions

## TransactionalOperator (preferred for explicit scope)

```java
@Service
@RequiredArgsConstructor
public class OrderService {
    private final OrderRepository orderRepo;
    private final InventoryRepository inventoryRepo;
    private final TransactionalOperator tx;

    public Mono<Order> place(OrderRequest req) {
        return tx.transactional(
            inventoryRepo.reserve(req.itemId(), req.qty())
                .then(orderRepo.save(new Order(req)))
        );
    }
}
```

Single reactive chain → single transaction. Commits on `verifyComplete()`, rolls back on error.

## @Transactional (annotation-based)

```java
@Service
@RequiredArgsConstructor
public class OrderService {
    private final OrderRepository orderRepo;
    private final InventoryRepository inventoryRepo;

    @Transactional
    public Mono<Order> place(OrderRequest req) {
        return inventoryRepo.reserve(req.itemId(), req.qty())
            .then(orderRepo.save(new Order(req)));
    }
}
```

Spring weaves a reactive transaction around the returned `Mono`. Works only if AOP can intercept (must be Spring bean + called from outside the class).

## Config

```java
@Configuration
@EnableTransactionManagement
public class R2dbcConfig {

    @Bean
    public ReactiveTransactionManager transactionManager(ConnectionFactory cf) {
        return new R2dbcTransactionManager(cf);
    }

    @Bean
    public TransactionalOperator transactionalOperator(ReactiveTransactionManager tm) {
        return TransactionalOperator.create(tm);
    }
}
```

## Propagation

Default: `REQUIRED` — joins existing or creates new.

For "must be in fresh transaction":

```java
@Transactional(propagation = Propagation.REQUIRES_NEW)
public Mono<Audit> log(Event event) { ... }
```

For "no transaction" (e.g., reading committed data outside outer tx):

```java
@Transactional(propagation = Propagation.NOT_SUPPORTED)
public Flux<Report> readOnlyReport(...) { ... }
```

## Anti-patterns

- Mixing `@Transactional` with `.block()` inside chain → blocks; defeats reactive.
- Calling `@Transactional` method from within same class → AOP doesn't intercept; no tx.
- `flatMap` after a `@Transactional` method returns → outer scope already closed; nested call won't join.
- Long-running tx (external HTTP call inside) → holds DB connection unnecessarily.
- Forgetting `@EnableTransactionManagement`.

## Read-only optimization

```java
@Transactional(readOnly = true)
public Flux<Order> listForUser(String userId) {
    return orderRepo.findByUserId(userId);
}
```

Postgres can optimize (no WAL writes). Worth marking for read-heavy services.

## Testing

```java
@DataR2dbcTest
class OrderServiceIT {
    @Autowired DatabaseClient client;

    @Test
    void rollbackOnError() {
        StepVerifier.create(service.place(badRequest))
            .expectError()
            .verify();

        StepVerifier.create(orderRepo.findAll())
            .expectComplete()  // no order saved due to rollback
            .verify();
    }
}
```
