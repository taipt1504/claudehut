---
name: implement
description: Use in the Implement phase whenever writing or editing production Java code, or fixing a bug, in a Spring/Spring Boot project. Enforces test-first (red-green-refactor), executes the approved plan step by step, and honors the project's path-scoped tech-stack rules and the task's enforcement set. Preloaded into claudehut-implementer.
---

# Implement (phase 4 of 6)

Execute the approved plan **test-first**, producing code that satisfies the spec and passes every applicable
rule. This skill is preloaded into `claudehut-implementer` (which runs in an isolated worktree) and is also
the main thread's playbook when implementing directly. The per-file tech-stack standards live in the
project's `.claude/rules/` tree and **auto-load by path** as you touch matching files — follow them; this
skill carries the workflow discipline and the deeper playbooks.

## Iron Law

```
NO PRODUCTION CODE WITHOUT A FAILING TEST FIRST
```

Wrote production code before the test? Delete it. Start over. **No exceptions** — don't keep it "as
reference," don't "adapt" it while writing the test, don't even look at it. Delete means delete.
**Violating the letter of this law is violating the spirit of it.**

## Preconditions (the write gate)

Production writes are denied by the `PreToolUse` gate until **all three** are true for this session:
`reuse_scan=true`, `spec_path` set, `plan_path` set. The RED test may be written first — the gate always
allows test paths (`*Test.java`, `*IT.java`, `*/test/*`). If a write is denied, you skipped a phase: go back.

## Flow

```mermaid
flowchart TB
    start([Implement phase]) --> plan["Read plans/&lt;task&gt;.md — ordered, test-first steps"]
    plan --> step["Take next plan step"]
    step --> red["RED — smallest failing test for the behavior<br/>run it; confirm it fails for the right reason"]
    red --> green["GREEN — minimal production code to pass<br/>(path-scoped rules in .claude/rules/ auto-load here)"]
    green --> rung{"tests green?"}
    rung -- no --> green
    rung -- yes --> refactor["REFACTOR with tests green"]
    refactor --> more{"more plan steps?"}
    more -- yes --> step
    more -- no --> done([REQUIRED NEXT: claudehut:review])
```

## The cycle

1. **RED** — write the smallest failing test for the next behavior. Run it; confirm it fails for the *right*
   reason (not a compile error you didn't intend).
2. **GREEN** — write the minimal production code to pass. Run it; confirm green.
3. **REFACTOR** — clean up while tests stay green.

Work the plan's steps in order. Honor the **enforcement set** recorded in Brainstorm — every listed skill and
rule must end up satisfied (Review audits exactly this set).

| Rationalization | Reality |
|--------|---------|
| "Too simple to test" | Simple code breaks. The test takes 30 seconds. |
| "I'll test after" | Tests-after answer "what does this do?", not "what should this do?" |
| "I already manually tested it" | Manual tests don't run in CI and prove nothing tomorrow. |
| "Deleting this code is wasteful" | Sunk cost. Unverified code is debt. |

## Tech-stack conventions — rules (edit-time) + playbooks (create-time)

Two surfaces, split by **measured** behavior (EVAL-REPORT #7):
- **Path-scoped rules** in `.claude/rules/` auto-load when you **read/edit an existing** matching file — terse standards, reliable on edits.
- **They do NOT fire when you CREATE a new file** (creation ≠ a read). **So when creating a new component, READ the matching playbook below FIRST.** These `references/*` playbooks are **context7-researched current best practice**, preloaded with this skill, and carry the create-time standard the path-rule would otherwise supply.

| Creating / editing… | READ this playbook (create-time) | Rule that auto-loads (edit-time) |
|---|---|---|
| MVC controller, DTO, validation, error mapping | `references/web.md` | `framework/spring-mvc`, `framework/jackson`, `security/input-validation` |
| WebFlux handler/router, Mono/Flux, R2DBC | `references/reactive.md` | `framework/webflux`·`r2dbc`, `performance/backpressure` |
| JPA entity / repository | `references/jpa.md` | `framework/jpa`·`lombok-jpa-safety`, `performance/n-plus-one` |
| Kafka/Rabbit/NATS listener/producer | `references/messaging.md` | `framework/kafka-consumer`·`kafka-producer`·`rabbitmq`·`nats` |
| Redis / `@Cacheable` cache code | `references/caching.md` | `framework/redis`, `performance/caching` |
| Security config, authz, deserialization, secrets | `references/security.md` | `security/spring-security`·`owasp-top10`·`secret-mgmt` |
| Flyway migration, index, datasource/pool | `references/persistence-ops.md` | `framework/flyway-naming`·`migration-safety`, `performance/indexing`·`connection-pool` |
| Tests (`*Test`/`*IT`), choosing a test type | `references/testing.md` | `testing/*` |
| Any Java — records, mappers, DI, style | `references/java-lang.md` | `coding/*`, `framework/mapstruct`·`lombok-*` |

**Create-time must-dos (do these even if you don't open the playbook).** Measured (EVAL-REPORT): at create-time
the playbook Read fires 13/15, but a *skipped* read is a real defect where the floor below doesn't carry the
rule — most acutely for security. These non-negotiables are therefore stated here, in the always-loaded skill
body, not only in the playbook file:
- **Security** — deny-by-default: `anyRequest().authenticated()` / `denyAll()`, then explicitly permit. **Never
  `.anyRequest().permitAll()` as the default** (silent open door). Use a `SecurityFilterChain` bean — never
  `WebSecurityConfigurerAdapter` (removed in Security 6). `@Valid` every `@RequestBody`; bind `*Request` DTOs,
  never `@Entity`. (full depth → `references/security.md`)
- **JPA** — set the fetch type explicitly (`@ManyToOne`/`@OneToOne` default to **EAGER** — make it `LAZY`); guard
  N+1 (fetch-join / `@EntityGraph`). No `@Data`/`@Builder`/`@EqualsAndHashCode` on `@Entity`. (→ `references/jpa.md`)
- **Messaging** — idempotent consumer (handlers replay); explicit ack/offset commit, not auto-ack-before-work;
  DLQ/retry for poison messages. (→ `references/messaging.md`)
- **Reactive** — never block the event loop: no `.block()`/blocking I/O inside a `Mono`/`Flux` chain or handler;
  offload blocking calls to a bounded scheduler. (→ `references/reactive.md`)

Cross-cutting Spring conventions that always apply: **constructor injection only** (no field `@Autowired`;
collaborators `final`), **thin controllers** (validate → one service call → map; DTOs not entities),
**services own the transaction boundary** (no web/persistence types leaking across), **externalized config**
via `@ConfigurationProperties`. Match the existing base package, layering, and naming from
`project-structure.md` / `vocabulary.md` — never invent a parallel structure.

## Red flags — STOP and start over

- Production code before a failing test
- "It's about spirit, not ritual" / "this case is different because…"
- A denied write you tried to route around instead of completing the missing phase

**REQUIRED NEXT:** `claudehut:review`.
