# Distributed Lock — Redisson

## Why Redisson, not raw SETNX

Raw `SETNX + EXPIRE` has race conditions:
- Lock could be released by wrong process.
- TTL extension during long operation is tricky.
- Reentrant locks not supported.

Redisson handles these correctly.

## Basic lock

```java
@Service
@RequiredArgsConstructor
public class OrderService {

    private final RedissonClient redisson;
    private final OrderRepository repo;

    public Order processOrder(String orderId) {
        RLock lock = redisson.getLock("order-process:" + orderId);
        try {
            boolean acquired = lock.tryLock(5, 30, TimeUnit.SECONDS);
            if (!acquired) {
                throw new LockAcquisitionException("could not acquire lock for " + orderId);
            }
            return doProcess(orderId);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new RuntimeException(e);
        } finally {
            if (lock.isHeldByCurrentThread()) {
                lock.unlock();
            }
        }
    }
}
```

`tryLock(waitTime, leaseTime, unit)`:
- Wait up to `waitTime` to acquire.
- Hold for `leaseTime` max (auto-release if process crashes).

## Fair lock

Order matters? Use fair lock — FIFO order.

```java
RLock lock = redisson.getFairLock("order-process:" + orderId);
```

## Read/write lock

```java
RReadWriteLock rwLock = redisson.getReadWriteLock("config:tenant:" + tenantId);

// Multiple readers OK
rwLock.readLock().lock();
try {
    return readConfig(tenantId);
} finally {
    rwLock.readLock().unlock();
}

// Exclusive writer
rwLock.writeLock().lock();
try {
    updateConfig(tenantId, newConfig);
} finally {
    rwLock.writeLock().unlock();
}
```

## Semaphore

Rate limiting concurrent operations:

```java
RSemaphore semaphore = redisson.getSemaphore("api-quota:user:" + userId);
semaphore.trySetPermits(100);

if (semaphore.tryAcquire(1, 1, TimeUnit.SECONDS)) {
    try {
        return callApi();
    } finally {
        semaphore.release();
    }
}
```

## Reactive variant

For WebFlux:

```java
RLockReactive lock = redisson.reactive().getLock("order:" + orderId);
return lock.tryLock(5, 30, TimeUnit.SECONDS)
    .flatMap(acquired -> acquired
        ? doProcessReactive(orderId).doFinally(s -> lock.unlock().subscribe())
        : Mono.error(new LockAcquisitionException(orderId)));
```

## Anti-patterns

- Holding lock across long external calls without lease time.
- Forgetting `isHeldByCurrentThread()` check before unlock (NPE risk).
- Lock keys not namespaced — collisions across features.
- Using lock for read-only operations — use read lock or no lock.

## Lock TTL strategy

`leaseTime` should be > P99 of the protected operation. If operation could exceed `leaseTime`, refresh:

```java
lock.tryLock(5, 60, TimeUnit.SECONDS);  // 60s lease
// for longer ops:
lock.tryLock(5, -1, TimeUnit.SECONDS);  // infinite lease + watchdog refreshes every 10s
```

`-1` enables Redisson watchdog (refreshes lease every 1/3 of `lockWatchdogTimeout`, default 30s).
