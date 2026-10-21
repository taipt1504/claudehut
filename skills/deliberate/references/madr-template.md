<!-- decision.md — MADR-style record of one design choice (pack deliberation). Keep it under 40 lines. -->
---
id: DEC-<task>-<n>   status: accepted   tier: T2   rule: [c]   variation_point: <concern, e.g. outbound.message.vendor>
---
## Context and Problem Statement
<one paragraph: what is being decided and why now>

## Decision Drivers
- <requirement / constraint / NFR>

## Variation analysis (probe)
| Question | Answer (tool + evidence path:line) |
|---|---|
| What varies? | |
| How does the repo handle it? | |
| Scale now / next | |

## Considered Options
1. Follow the existing pattern (<pattern id, canonical file>) — rule: …
2. Write directly — rule: none
3. <other>

## Decision Outcome
Chosen option: <n>, because <rule (a)/(b)/(c) and the reason>.

## Consequences
- Good, because …
- Bad, because …

## Confirmation
<test name or ArchUnit rule that keeps this decision true>

## Deferred variation points
<if written directly: the point deferred and when to revisit>
