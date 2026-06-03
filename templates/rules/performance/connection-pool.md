---
id: rules/performance/connection-pool
paths:
  - "**/application*.properties"
  - "**/application*.yml"
severity: medium
tags: [hikaricp, r2dbc-pool, performance]
---
<!-- ClaudeHut rule template — generated into .claude/rules/performance/connection-pool.md by claudehut-init. Reused & enhanced from committed rules/performance/connection-pool.md. -->


# Connection Pool Sizing

## HikariCP (JDBC)

### Defaults

Boot 3.x default: `maximum-pool-size = 10`.

Often too low for production. Often too high → exhausts DB connection slots.

### Sizing formula (PostgreSQL Wiki)

```
connections = ((core_count * 2) + effective_spindle_count)
```

For modern SSD, `effective_spindle_count = 0`. So baseline:

```
pool_size = cpu_cores * 2
```

For 8-core service: `maximum-pool-size = 16`.

### Spring config

```yaml
spring:
  datasource:
    hikari:
      maximum-pool-size: 16
      minimum-idle: 4
      connection-timeout: 3000         # ms; should be < your request SLA
      idle-timeout: 600000             # 10 min
      max-lifetime: 1800000            # 30 min
      validation-timeout: 250
      leak-detection-threshold: 30000  # 30s; alerts if connection held too long
```

### Don't oversize

If 10 instances × 50 pool size = 500 connections to one DB → may exceed Postgres `max_connections` (default 100). Use PgBouncer as connection multiplexer.

## R2DBC Pool

```yaml
spring:
  r2dbc:
    pool:
      initial-size: 5
      max-size: 20
      max-acquire-time: 3s
      max-create-connection-time: 5s
      max-idle-time: 10m
      max-life-time: 30m
```

R2DBC is non-blocking — same connection serves many concurrent operations. Pool can be smaller than HikariCP for equivalent throughput.

## Timeout coordination

```
connection_timeout < request_timeout < downstream_dependency_timeout
```

Example:
- `hikari.connection-timeout = 3s`.
- Your service's request SLA = 5s.
- Downstream API call max = 4s.

If connection-timeout > request SLA → request fails with connection timeout instead of completing.

## Monitoring

Expose pool metrics:

```yaml
management:
  metrics:
    export:
      prometheus:
        enabled: true
```

Metrics:
- `hikaricp.connections.active` — currently in use.
- `hikaricp.connections.idle` — idle.
- `hikaricp.connections.pending` — waiting for a connection.
- `hikaricp.connections.acquire` — time to acquire (P95).

Alert if `pending > 0` for sustained period.

## Per-DB pool

If using multiple DBs (read replica + write master):

```yaml
spring:
  datasource:
    write:
      hikari:
        maximum-pool-size: 16
    read:
      hikari:
        maximum-pool-size: 32  # more reads
```

## Anti-patterns

- Default `maximum-pool-size = 10` for high-traffic service → connection-wait queue.
- Oversized pool blows up DB connection limit.
- Leak detection disabled → blocking I/O within transaction holds connection too long.
- Same pool size across all environments (dev / staging / prod) — tune per env.
- `connection-timeout = 30s` (default) — masks DB issues; should be < 5s.
