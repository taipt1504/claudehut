---
id: rules/architecture/adr-format
paths:
  - "docs/adr/**/*.md"
severity: low
tags: [adr, decisions, madr]
---


# Architecture Decision Records (MADR)

## Why

Capture decision context for future maintainers. Why we chose X over Y.

## Where

`docs/adr/NNNN-decision-title.md`.

NNNN = zero-padded sequence number: `0001`, `0002`, ...

## Format (MADR — Markdown ADR)

```markdown
# 0042 — Use R2DBC over JPA for Order Service

* Status: accepted
* Date: 2025-05-27
* Deciders: backend-team, tech-lead
* Tags: persistence, reactive

## Context and Problem Statement

Order Service handles 1000+ req/s with 95% reads. Spring MVC stack with JPA
showed thread saturation under load tests. Need a stack that doesn't block.

## Decision Drivers

- Throughput target: 1500 req/s.
- Latency p95 ≤ 200ms.
- Team has Spring + WebFlux experience.
- Existing Postgres schema.

## Considered Options

1. Spring WebFlux + R2DBC
2. Keep Spring MVC + JPA + tune Tomcat
3. Spring WebFlux + JPA (with Schedulers.boundedElastic for blocking)

## Decision Outcome

Chosen option: **1. Spring WebFlux + R2DBC**.

Justification:
- Removes blocking I/O end-to-end.
- Matches WebFlux ecosystem (consistent reactive style).
- Team has experience.

## Consequences

Positive:
- Throughput meets target in load test (verified 1600 req/s with 100 vUsers).
- Lower CPU usage (no thread context switch).

Negative:
- Loss of JPA features (cascading, lazy loading).
- Learning curve for team members not familiar with R2DBC.
- Some JPA-specific tooling (Hibernate validator integration) requires workaround.

Mitigations:
- Pair programming sessions for first 2 sprints.
- ClaudeHut `r2dbc` skill enforces conventions.

## Links

- [Spring WebFlux docs](https://docs.spring.io/spring-framework/reference/web/webflux.html)
- [R2DBC docs](https://r2dbc.io/)
- Related ADR: 0038-choose-webflux-for-new-services
```

## When to write an ADR

- Picking a database, framework, library.
- Choosing an architectural pattern (CQRS, event sourcing).
- API versioning strategy.
- Deployment topology.
- Authentication method.

## When NOT

- Trivial code organization choices.
- Choices reversible without effort.
- Internal implementation details.

## Lifecycle

- `proposed` → discussion in progress.
- `accepted` → decision made and implemented (or to be).
- `deprecated` → superseded; reference the superseding ADR.
- `superseded by ADR-NNNN`.

Never delete an ADR. Mark deprecated; new ADR references it.

## Tooling

- `adr-tools` CLI: `adr new "Use R2DBC over JPA"`.
- Phase 2 Spec skill prompts user "Should we write an ADR?" when decision logged.
