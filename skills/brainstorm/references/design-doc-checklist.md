# Design Doc Self-Review Checklist

Before requesting user approval, run through this checklist. Fix all ✗ inline.

## Structure

- [ ] Has Overview section (≤ 3 sentences)
- [ ] Has Components section (Mermaid diagram if > 2 components interact)
- [ ] Has Data Flow section
- [ ] Has Error Handling section
- [ ] Has Testing Strategy section
- [ ] Has NFR section with **numbers** (not adjectives)

## Content quality

- [ ] No "TBD", "etc.", "and so on", "similar to"
- [ ] No vague verbs like "handle", "manage", "process" without specifics
- [ ] Every component has a single, clearly stated responsibility
- [ ] Public API surface (signatures, endpoints) appears identically wherever referenced
- [ ] Error paths enumerated (not just "throw exception")

## Scope discipline

- [ ] No features beyond what user asked
- [ ] No "future-proofing" abstractions
- [ ] No premature configurability ("we'll make this pluggable later")
- [ ] If reuse candidate exists, design either uses it OR explains why not

## Stack alignment

- [ ] Matches detected `web_stack` (MVC ↔ Controller / WebFlux ↔ Handler)
- [ ] Matches detected ORM (JPA vs R2DBC pattern)
- [ ] References specific tech-stack skill (e.g., "see claudehut:spring-webflux for handler conventions")
- [ ] Migration plan addressed if DB schema delta exists

## Decision traceability

- [ ] Each "we chose X" has a 1-line rationale
- [ ] Alternatives considered are listed (even briefly)
- [ ] Trade-offs explicitly named

If 3 or more items fail → return to step 4 (propose) before showing to user.
