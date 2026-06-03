<!-- ClaudeHut MCP recommendation catalog. Read by claudehut-init to SUGGEST (never auto-install) MCP servers per detected stack. ClaudeHut ships NO active .mcp.json — MCP is opt-in per project. See docs/design/08-mcp-integration.md. -->

# MCP recommendation catalog

ClaudeHut does **not** bundle or auto-connect any MCP server. Instead, `claudehut-init` detects the project's
stack and **suggests** the servers below — the developer runs the `claude mcp add` commands they want.
Project-scoped servers land in the project's own `.mcp.json` (created by `claude mcp add --scope project`, not
shipped by the plugin) and require per-server approval before use. The Review auditors **degrade gracefully**
when a server is absent (they review statically) — nothing here is required for the workflow to run.

How init uses this file: for each **tech-stack** row whose `detect-when` matches a detected dependency, emit
its command; always offer the **memory** and **research** rows. Present them as a copy-pasteable block under
"Recommended MCP servers for this project (optional)". Replace `<…>` placeholders and never print real
secrets — tell the user to substitute their own connection string / token at run time.

## Bucket 1 — tech-stack (emit per detected dependency)

| Server | detect-when | Phase value | `claude mcp add` command (project scope) |
|--------|-------------|-------------|------------------------------------------|
| postgres | `org.postgresql` / `r2dbc-postgresql` / Postgres in compose | Brainstorm, Review — live schema + `EXPLAIN` for db/perf reviewers | `claude mcp add --scope project postgres -- npx -y @modelcontextprotocol/server-postgres "<POSTGRES_URL>"` |
| mysql | `mysql-connector` / `r2dbc-mysql` / MySQL in compose | Brainstorm, Review — schema + `EXPLAIN` | `claude mcp add --scope project mysql -- npx -y mcp-server-mysql --url "<MYSQL_URL>"` |
| redis | `spring-data-redis` / `lettuce` / `jedis` | Review — cache inspection | `claude mcp add --scope project redis -e REDIS_URL="<REDIS_URL>" -- npx -y redis-mcp-server` |
| kafka | `spring-kafka` / `kafka-clients` | Implement, Review — topic/consumer-group lag (uses the shipped stub `bin/kafka-mcp` — read-only, see 08 §3) | `claude mcp add --scope project kafka -e KAFKA_BOOTSTRAP_SERVERS="<HOST:9092>" -- "${CLAUDE_PLUGIN_ROOT}/bin/kafka-mcp"` |
| github | git remote on github.com | Plan, Review, Learn — PR/issue context | `claude mcp add --scope project --transport http github https://api.githubcopilot.com/mcp/ --header "Authorization: Bearer <GITHUB_TOKEN>"` |

> RabbitMQ / NATS: no mature public MCP at time of writing — add by the same pattern when one ships.

## Bucket 2 — memory (offer to any project)

| Server | Purpose | `claude mcp add` command (user scope) |
|--------|---------|---------------------------------------|
| memory | A persistent knowledge-graph memory MCP to complement ClaudeHut's committed `.claude/claudehut/` memory (machine-local, optional). | `claude mcp add --scope user memory -- npx -y @modelcontextprotocol/server-memory` |

## Bucket 3 — research (offer to any project)

| Server | Purpose | `claude mcp add` command (user scope) |
|--------|---------|---------------------------------------|
| context7 | Up-to-date library/framework docs (Spring, Hibernate, Reactor, …) for the brainstormer's best-practice axis. | `claude mcp add --scope user --transport http context7 https://mcp.context7.com/mcp` |

> Manage/inspect installed servers with `/mcp`; remove with `claude mcp remove <name>`.
