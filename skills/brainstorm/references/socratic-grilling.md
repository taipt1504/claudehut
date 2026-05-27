# Socratic Grilling Protocol

## Table of contents

- [Question sequence](#question-sequence)
- [Anti-patterns to avoid](#anti-patterns-to-avoid)
- [Stopping criteria](#stopping-criteria)
- [When user is vague](#when-user-is-vague)

## Question sequence

Ask in this order, ONE per turn. Skip a question if the user already answered it.

1. **Q1 — Business purpose**: What problem does this solve for the user? Who uses it?
2. **Q2 — Boundaries**: Where is the input/output? Inbound REST API? gRPC? Kafka consumer? Scheduled job? In-process call?
3. **Q3 — Hard constraints**: What MUST be true? Perf budget? Concurrency model? Data consistency requirement (strong/eventual)? SLA?
4. **Q4 — Reuse confirmation**: Show top reuse-scan candidates. Ask: reuse / adapt / refuse for each.
5. **Q5 — Definition of done**: What concrete observable behavior signals success? (Ideally 1-3 binary criteria.)

## Anti-patterns to avoid

- **Batched questions**: "What's the input, what's the output, and what's the SLA?" → split into 3 turns.
- **Leading questions**: "You want CQRS here, right?" → ask open-ended instead.
- **Solution-first questions**: "Should we use Kafka or RabbitMQ?" → only ask after Q1-Q3 reveal the constraints.
- **Yes/no questions**: prefer open-ended "what" / "how" / "when".
- **Asking when memory has the answer**: read `conventions.md` first.

## Stopping criteria

Stop grilling and move to approach proposal when ANY of:

- User has answered Q1, Q2, Q3, Q5 with concrete information.
- 5 rounds completed (cap).
- User explicitly says "just propose something" or equivalent.
- The problem is genuinely simple (e.g., add a field to an existing DTO) and 2 rounds suffice.

## When user is vague

If after Q1 the user is still vague, do NOT keep grilling. Instead:

- Propose 2 candidate interpretations.
- Ask: "Which interpretation is closer to what you mean?"
- Do not invent a third interpretation; force a binary choice if possible.

This converges faster than open grilling on a fuzzy target.
