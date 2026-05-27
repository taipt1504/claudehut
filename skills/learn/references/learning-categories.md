# Learning Categories — Extraction Heuristics

## pattern

Code shape that worked well and would work again. Capture when:

- A non-obvious idiom solved the problem cleanly.
- A combination of annotations/configs was tricky to discover.
- A library API has multiple choices and one is clearly best for this stack.

Example title: `Use Result<T, E> wrapper from common module for service return types`

## anti-pattern

A trap avoided or a fix learned the hard way. Capture when:

- A test failure revealed a common mistake.
- A reviewer finding pointed out a project-specific gotcha.
- An API "obvious" use is actually wrong.

Example title: `Do not call .block() on Mono inside a @KafkaListener — use blockingExecutor scheduler`

## decision

A trade-off chosen with rationale. Capture when:

- Brainstorm proposed 2-3 approaches and one was chosen.
- A config value was tuned vs default.
- A library was selected over alternatives.

Example title: `Chose Redisson distributed lock over Lettuce SETNX for fairness`

## gotcha

Non-obvious behavior in framework/library. Capture when:

- Debugging revealed unexpected runtime behavior.
- Documentation contradicts observed behavior.
- A version upgrade changed semantics.

Example title: `Spring 6 Bean Validation no longer triggers on @PathVariable without @Validated on controller`

## command

A reusable build/test/ops command that's non-obvious. Capture when:

- A specific Gradle/Maven invocation is recurring.
- A jq/awk one-liner solved a parsing problem.
- A test isolation flag is required.

Example title: `./gradlew integrationTest --tests '*KafkaIT' -PtestKafkaImage=confluentinc/cp-kafka:7.5.0`

## When NOT to extract

- Vague observations ("the code is cleaner now").
- Already-documented framework idioms (don't restate Spring docs).
- One-off project quirks unlikely to recur.
- Anything that names specific business identifiers (customer IDs, account numbers) — privacy risk.

## Quality bar

Each entry should be:

- **Specific**: cites a concrete class/method/config, not a vibe.
- **Reusable**: the next person can apply it directly.
- **Self-contained**: 2-5 sentences without requiring the original task context.
- **Tagged**: 2-5 tags for retrieval.
