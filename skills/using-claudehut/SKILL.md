---
name: using-claudehut
description: ClaudeHut skill-discovery contract, preloaded into every dispatch-eligible subagent via `skills:` frontmatter. Supplies the skill-invocation discipline plus the catalog of plugin skills with trigger excerpts, so a subagent decides which skills to invoke when its task touches an uncovered domain.
---

# Using ClaudeHut — subagent skill discipline

You are running as a ClaudeHut subagent. Your context window is fresh
and isolated from the main thread. The plugin skills are reachable
through the `Skill` tool; the catalog at the bottom of this file is the
authoritative list of what is available.

## Skill invocation rule

> **When the work clearly falls within a skill's domain, you MUST
> invoke that skill before acting — don't reinvent what it covers.**

Before you write code, edit a config, draft an artifact, or answer a
domain question, scan the catalog. If a row clearly matches the
work — invoke that skill via the `Skill` tool **first**, then continue.

Use judgment on the threshold: a clear domain (or sub-domain) match →
invoke; a remote, tangential association → don't force it. Path-specific
guidance auto-loads via the rules layer, so an open file alone is not a
reason to invoke. Match in catalog → invoke. Read the skill body. Apply
the conventions. Then act.

## Red flags (rationalizations that mean "invoke the skill")

| Rationalization                                  | Reality |
|--------------------------------------------------|---------|
| "I already know this pattern."                   | Your training data is generic; the skill is project-tuned. |
| "Task is small."                                 | Small tasks are how silent drift accumulates. |
| "Skill invocation is overkill."                  | Invocation is near-zero cost; skipping risks rule violation. |
| "My preloaded skills already cover it."          | Preload is a starter kit, not exhaustive coverage. |
| "I'll guess and verify later."                   | Guessing first burns turns and produces non-conforming code. |
| "It's just a one-line change."                   | Conventions decide what that one line should look like. |

## How dispatch maps to skill invocation

You arrived here because the main thread dispatched a phase via `Task`
with a `subagent_type` (e.g. `claudehut-builder`). The phase skill the
main thread invoked (e.g. `claudehut:build`) is also preloaded into
your `skills:` frontmatter. You do **not** need to re-invoke your phase
skill. You **do** need to invoke any domain skill your work touches.

Examples:

| Your phase agent          | Work in front of you           | Skill to invoke |
|---------------------------|--------------------------------|------------------|
| `claudehut-builder`       | Touching `*Controller.java`    | `claudehut:spring-mvc` (or `spring-webflux` per stack) |
| `claudehut-builder`       | Touching `*KafkaListener.java` | `claudehut:kafka-consumer` |
| `claudehut-builder`       | Touching `*Producer.java`      | `claudehut:kafka-producer` |
| `claudehut-builder`       | Touching `*Mapper.java`        | `claudehut:mapstruct` |
| `claudehut-builder`       | Touching `*Dto/*Request/*Response.java` | `claudehut:jackson` |
| `claudehut-builder`       | Touching `*Repository.java`    | `claudehut:jpa-hibernate` (or `r2dbc` per stack) |
| `claudehut-builder`       | Touching `db/migration/V*.sql` | `claudehut:flyway-migration` |
| `claudehut-builder`       | Any `.java` file with a Lombok annotation (`@Data`, `@Value`, `@Builder`, `@SuperBuilder`, `@Slf4j`, `@RequiredArgsConstructor`, …) or `lombok.*` import | `claudehut:lombok` |
| `claudehut-builder`       | New Java file                  | `claudehut:reuse-scan` |
| `claudehut-builder`       | Adding `*Test.java`            | `claudehut:tdd-cycle` (preloaded — already in context) |
| `claudehut-builder`       | Adding `*IT.java`              | `claudehut:testcontainers` |
| `claudehut-verifier`      | Pre-dispatching reviewers      | `claudehut:verify-review` (preloaded) |
| Any agent                 | Bug investigation              | `claudehut:systematic-debug` |
| Any agent                 | Stuck/no convergence           | `claudehut:systematic-debug` |

If the work touches multiple domains, invoke each matching skill in
order. The Skill tool is idempotent — calling the same skill twice in
one task is harmless.

## When you are unsure

Default to **invoke**. The bar to skip a catalog match is "I can
articulate why the skill is irrelevant to this exact line of work and
write it in a comment for the reviewer." If you cannot, invoke.

## Termination contract — never try to ask the user

Anthropic's subagent runtime documents these tools as **unavailable in
any subagent context, even when listed in your `tools:` frontmatter**
(source: code.claude.com/docs/en/sub-agents §Available tools):

- `Agent`
- `AskUserQuestion`
- `EnterPlanMode`
- `ExitPlanMode` (unless your `permissionMode` is `plan`)
- `ScheduleWakeup`
- `WaitForMcpServers`

If you try to call `AskUserQuestion` from this subagent, the tool call
is filtered out by the runtime — your turn either stalls or returns an
empty response. This is the documented behaviour, not a bug to work
around.

**The pattern instead is scan-and-return:**

1. Scan, invoke the skills you need, draft any artifact on disk.
2. Emit a structured return block (your phase agent definition spells
   out the exact shape — e.g. `claudehut-brainstorm-return`).
3. Surface every decision the user must make as data inside that
   return block (typically `open_questions[]` with `options[]`).
4. Terminate.

The main thread then calls `AskUserQuestion` on your behalf, collects
the user's answers, and re-dispatches you with the answers folded into
the next turn's prompt. Never wrap a "Q1/5: ... Q2/5: ..." dialog inside
a single turn — that pattern reaches a runtime that cannot relay it.

## Catalog

<!-- catalog:begin -->

| Skill | When to invoke (description excerpt) |
|-------|--------------------------------------|
| `claudehut:arch-unit-check` | Run ArchUnit tests if present in project to enforce package-layout/hexagonal/DDD rules. Used in Phase 5 verify stage. Optional — skips if ArchUnit not on classpath. Slash-invoke  |
| `claudehut:brainstorm` | Phase 1 of ClaudeHut — scan the codebase + reuse-detection, draft a design doc, resolve open decisions via AskUserQuestion, converge on an approved design. Use when the user requ |
| `claudehut:build` | Phase 4 of ClaudeHut — execute the approved plan by dispatching each parallel group as concurrent native builder subagents (Task, each in its own git worktree), then merging. Gro |
| `claudehut:discover` | Show ClaudeHut plugin status — active task, current phase, detected stack, loaded skills/agents/rules/hooks, integration backends (Understand-Anything, Graphify), and MCP server  |
| `claudehut:flyway-migration` | Flyway migration conventions for PostgreSQL/MySQL — naming, online-safe DDL (CREATE INDEX CONCURRENTLY, expand-contract for renames), idempotency, backfill patterns. Auto-loads w |
| `claudehut:init` | Scaffold the .claudehut/ directory in the current Java project (creates memory/, specs/, plans/, state/, rules/ subdirs and seeds template configs). Run via /claudehut:init when fi |
| `claudehut:jackson` | Jackson serialization conventions for Spring Boot 3.x: ObjectMapper config, polymorphic deserialization (subtype whitelist), JavaTimeModule, mixins, mass-assignment prevention. Inv |
| `claudehut:jpa-hibernate` | JPA + Hibernate conventions for Spring Boot 3.x servlet stack. Auto-loads when editing `**/*Repository.java`, `**/*Entity.java` in projects with orm=jpa. Covers @Entity mapping, fe |
| `claudehut:kafka-consumer` | Spring Kafka consumer conventions — @KafkaListener, manual ack modes, DLT pattern, retry topic, idempotency via dedup store, JSON/Avro deserialization. Auto-loads when editing `* |
| `claudehut:kafka-producer` | Spring Kafka producer conventions — idempotent producer config, transactional outbox pattern, Schema Registry integration, JSON/Avro serialization, retry + backoff. Auto-loads wh |
| `claudehut:learn` | Phase 6 of ClaudeHut — extract patterns, anti-patterns, decisions, and reusable snippets from the completed task; persist to .claudehut/memory/learnings.jsonl, update index.md, o |
| `claudehut:lombok` | Project Lombok conventions for Java/Spring Boot 3.x — safe-annotation matrix, JPA-entity/Jackson/MapStruct interop traps, builder patterns with inheritance, recommended lombok.co |
| `claudehut:mapstruct` | MapStruct mapper conventions for Java. Auto-loads when editing `**/*Mapper.java` files with @Mapper annotation. Covers @Mapping/@MappingTarget/@BeanMapping config, null strategies, |
| `claudehut:nats` | NATS / JetStream consumer + publisher conventions for Java (jnats). Auto-loads when editing `**/*NatsListener*.java`, `**/*NatsClient*.java` in projects with messaging=nats. Covers |
| `claudehut:owasp-scan` | Run OWASP dependency-check + custom Spring Security misconfig regex scans. Used in Phase 5 verify stage. Slash-invoke /claudehut:owasp-scan for on-demand scans. Outputs structured  |
| `claudehut:plan` | Phase 3 of ClaudeHut — break an approved contract into a file-level task list: 2-5 min chunks, exact paths, RED test commands, GREEN steps, DAG dependencies, risk callouts. Produ |
| `claudehut:r2dbc` | Reactive R2DBC conventions for Spring Boot 3.x WebFlux stack. Auto-loads when editing `**/*Repository.java` in projects with orm=r2dbc. Covers ReactiveCrudRepository, R2dbcEntityTe |
| `claudehut:rabbitmq` | Spring AMQP (RabbitMQ) conventions — exchange/queue/binding topology, manual ack, DLX (dead-letter exchange) pattern, retry policy, message TTL. Auto-loads when editing `**/*Rabb |
| `claudehut:redis-cache` | Spring Data Redis conventions — caching with @Cacheable, key strategy, TTL/eviction policies, Redisson distributed lock patterns. Auto-loads when editing `**/*Cache*.java` or fil |
| `claudehut:reuse-scan` | Quet codebase tim impl tai su dung duoc truoc khi tao class moi (Java backend). Uu tien plugin da cai (Understand-Anything, Graphify) qua slash command native; fallback grep + heur |
| `claudehut:route` | Phase 0.5 of ClaudeHut — triage task intent and choose pipeline DEPTH (the Routing pattern): quick (build+verify) or full (6-phase), recorded as .claudehut/state/route-<id>.json. |
| `claudehut:spec` | Phase 2 of ClaudeHut workflow — convert an approved design document into a binary behavioral contract (Given/When/Then, API shape, edge cases, NFRs). Use immediately after Brains |
| `claudehut:spring-mvc` | Spring MVC REST controller conventions for Java Spring Boot 3.x. Auto-loads when editing `**/*Controller.java` files in projects with web_stack=mvc. Covers @RestController, validat |
| `claudehut:spring-webflux` | Spring WebFlux conventions for Java Spring Boot 3.x reactive stack. Auto-loads when editing `**/*Handler.java` or `**/*Controller.java` in projects with web_stack=webflux. Covers R |
| `claudehut:systematic-debug` | Structured debugging protocol — reproduce → isolate (bisect) → root cause → test → fix. Used on-demand when a bug appears outside Phase Loop (e.g., user reports a failing |
| `claudehut:tdd-cycle` | Enforce strict RED -> GREEN -> REFACTOR for Java/Spring code; required for every Build task. Detects and rejects anti-patterns (prod-before-test, test-after, manual-test rationaliz |
| `claudehut:testcontainers` | Testcontainers for Java integration tests — singleton vs per-class lifecycle, reuse flag, network sharing, Postgres/Kafka/Redis containers, dynamic Spring properties. Auto-loads  |
| `claudehut:verify-review` | Phase 5 of ClaudeHut — run the verify pipeline (build/tests/coverage/lint/static/security) via a gate-runner subagent, then fan out reviewer subagents in parallel, aggregate shar |
| `claudehut:wiremock-stub` | WireMock stub conventions for HTTP integration tests. Stub mapping JSON format, scenario-based stateful stubs, request matching strategies, fault injection. Auto-loads when editing |
| `claudehut:write-skill` | Scaffold a new ClaudeHut skill in the 3-bucket layout (SKILL.md + references/ + scripts/ + assets/): validates the frontmatter contract, applies naming conventions, generates a ske |

_Auto-generated from `skills/*/SKILL.md` by `scripts/regen-using-claudehut.sh`. Do not hand-edit this block._

<!-- catalog:end -->
