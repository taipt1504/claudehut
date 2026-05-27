# Project Conventions

> Edit this file to capture conventions your team follows that differ from
> ClaudeHut defaults. Agents and skills read this to adapt their behavior.
> Keep it short and concrete — bullet points, not prose.

## Architecture

- Package layout: <hexagonal | layered | feature-slice>
- Module boundaries: <describe how modules relate>

## Naming

- Domain language: <list key terms used in this codebase>
- Special prefixes/suffixes: <e.g., `*Aggregate`, `*Event`>

## Testing

- Test framework: JUnit 5 + Mockito (default). Reactive: StepVerifier.
- Integration test convention: `*IT.java` under `src/integrationTest/java/`.
- Mock policy: <do/don't mock>

## Build & CI

- Format: <Spotless / google-java-format>
- Static analysis: <SpotBugs / PMD / SonarLint>
- Required gates before merge: <list>

## Custom rules

- <add team-specific rule>
- <add team-specific rule>
