---
name: discover
description: Show ClaudeHut plugin status — active task, current phase, detected stack, loaded skills/agents/rules/hooks, integration backends (Understand-Anything, Graphify), and MCP server status. Run via /claudehut:discover when you need to know what the plugin is doing right now.
---

# Discover — ClaudeHut Status

Read-only diagnostic. No state mutation.

## Quick start

Run `scripts/render-discover.sh`. Output goes to chat as a table.

## What it shows

```
ClaudeHut · v<version>

ACTIVE TASK
  task_id: 2025-05-27-add-user-endpoint
  phase:   build  (approvals: brainstorm ✓, spec ✓, plan ✓)
  branch:  feature/add-user-endpoint
  loop_retries: 0/3

STACK
  build:     gradle-kotlin · java 21 · Spring Boot 3.3.4
  web:       webflux
  orm:       r2dbc
  db:        postgresql
  messaging: kafka
  cache:     redis
  mapper:    mapstruct 1.5.5
  ser:       jackson 2.17.2

INTEGRATIONS
  understand_anything: ✓ (.understand-anything/knowledge-graph.json)
  graphify:            ✓ (graphify-out/graph.json, global=true)

PHASE SKILLS (6)
  brainstorm spec plan build verify-review learn

META SKILLS (loaded as needed)
  discover init reuse-scan

AGENTS (7 loaded)
  claudehut-orchestrator (active)
  claudehut-brainstormer claudehut-spec-writer claudehut-planner
  claudehut-builder claudehut-verifier claudehut-learner

RULES (auto-loaded session)
  naming · package-layout · tdd-cycle · owasp-top10 · coverage

HOOKS (8 events)
  SessionStart UserPromptSubmit PreToolUse PostToolUse
  SubagentStop Stop PreCompact FileChanged

MCP SERVERS
  context7 ✓ · memory ✓ · sequential-thinking ✓ · github - · postgres -

RECENT LEARNINGS (last 3)
  - [pattern] Use ServerWebExchange to read userInfo header in WebFlux
  - [decision] Chose r2dbc-pool size = core×2 for higher throughput
  - [gotcha] Jackson @JsonTypeInfo defaultImpl breaks subtype whitelisting
```

## Exit criteria

- [ ] Diagnostic rendered to chat
- [ ] No state file modified
